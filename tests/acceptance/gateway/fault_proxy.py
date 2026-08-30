#!/usr/bin/env python3
"""Policy-pinned, no-MITM CONNECT fault proxy for VM-006."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import select
import socket
import stat
import sys
import threading
from pathlib import Path
from typing import IO, Dict, Iterable, Optional, Tuple


MAX_HEADER = 16 * 1024
MAX_POLICY_BYTES = 64 * 1024
BIND_ADDRESS = "192.168.77.1"
BIND_PORT = 7897
ALLOWED_CLIENT = ipaddress.ip_address("192.168.77.10")
PROBE_HOST = "www.microsoft.com"
DROP_AFTER_BYTES = 65536
CONNECT_TIMEOUT_SECONDS = 10.0
CLIENT_HEADER_TIMEOUT_SECONDS = 10.0
MAX_CONCURRENT_CONNECTIONS = 16
RULE_ROLES = frozenset({"probe", "metadata", "payload"})
LOG_ROLES = frozenset({*RULE_ROLES, "unknown"})
LOG_EVENTS = frozenset(
    {
        "client-rejected",
        "connection-limit",
        "connect-rejected",
        "proxy-error",
        "relay-closed",
        "target-not-allowed",
        "transfer-dropped",
        "upstream-closed-before-drop",
    }
)
HOST_PATTERN = re.compile(
    r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z"
)


def _object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("policy JSON contains a duplicate property")
        result[key] = value
    return result


def _require_exact_keys(value: dict, expected: Iterable[str], label: str) -> None:
    if type(value) is not dict:
        raise ValueError(f"{label} must be an object")
    expected_set = set(expected)
    actual_set = set(value)
    if actual_set != expected_set:
        raise ValueError(f"{label} properties do not match the strict schema")


def _read_private_json(path: Path) -> Tuple[dict, str]:
    try:
        before = path.lstat()
    except OSError as exc:
        raise ValueError("policy file cannot be inspected") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ValueError("policy must be a regular non-symlink file")
    if hasattr(os, "getuid") and before.st_uid != os.getuid():
        raise ValueError("policy must be owned by the invoking user")
    if hasattr(os, "getuid") and stat.S_IMODE(before.st_mode) != 0o600:
        raise ValueError("policy permissions must be exactly 0600")

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError("policy file cannot be opened safely") from exc
    try:
        after = os.fstat(descriptor)
        if not stat.S_ISREG(after.st_mode):
            raise ValueError("opened policy is not a regular file")
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("policy identity changed while opening")
        if hasattr(os, "getuid") and after.st_uid != os.getuid():
            raise ValueError("policy ownership changed while opening")
        if hasattr(os, "getuid") and stat.S_IMODE(after.st_mode) != 0o600:
            raise ValueError("policy permissions changed while opening")
        if after.st_size < 2 or after.st_size > MAX_POLICY_BYTES:
            raise ValueError("policy size is outside the accepted range")
        chunks = []
        size = 0
        while True:
            chunk = os.read(descriptor, 8192)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_POLICY_BYTES:
                raise ValueError("policy exceeds the size limit")
            chunks.append(chunk)
        raw = b"".join(chunks)
        if len(raw) < 2:
            raise ValueError("policy size is outside the accepted range")
    finally:
        os.close(descriptor)
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_object_without_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise ValueError(f"policy is not strict UTF-8 JSON: {exc}") from exc
    if type(value) is not dict:
        raise ValueError("policy root must be an object")
    return value, hashlib.sha256(raw).hexdigest()


def _is_global_unicast_ipv4(address: ipaddress._BaseAddress) -> bool:
    return bool(
        address.version == 4
        and address.is_global
        and not address.is_multicast
        and not address.is_reserved
        and not address.is_unspecified
        and not address.is_loopback
        and not address.is_link_local
    )


def _is_dns_name(host: object) -> bool:
    if type(host) is not str or not HOST_PATTERN.fullmatch(host):
        return False
    if all(label.isdigit() for label in host.split(".")):
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return True
    return False


@dataclasses.dataclass(frozen=True)
class ProxyRule:
    host: str
    role: str
    action: str
    addresses: Tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Policy:
    profile: str
    rules: Dict[str, ProxyRule]
    drop_after_bytes: int
    connect_timeout: float
    sha256: str

    def rule_for(self, host: str) -> Optional[ProxyRule]:
        return self.rules.get(host)


def load_policy(path: Path) -> Policy:
    value, digest = _read_private_json(path)
    _require_exact_keys(
        value,
        ("schemaVersion", "profile", "dropAfterBytes", "connectTimeoutSeconds", "rules"),
        "policy",
    )
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("policy schemaVersion must be integer 1")
    profile = value["profile"]
    if type(profile) is not str or profile not in {"vm006a", "vm006b"}:
        raise ValueError("policy profile must be vm006a or vm006b")
    if type(value["dropAfterBytes"]) is not int or value["dropAfterBytes"] != DROP_AFTER_BYTES:
        raise ValueError(f"dropAfterBytes must be {DROP_AFTER_BYTES}")
    timeout = value["connectTimeoutSeconds"]
    if (
        not isinstance(timeout, (int, float))
        or isinstance(timeout, bool)
        or float(timeout) != CONNECT_TIMEOUT_SECONDS
    ):
        raise ValueError(f"connectTimeoutSeconds must be {int(CONNECT_TIMEOUT_SECONDS)}")
    raw_rules = value["rules"]
    if type(raw_rules) is not list or not raw_rules:
        raise ValueError("policy rules must be a non-empty array")

    rules: Dict[str, ProxyRule] = {}
    for index, raw_rule in enumerate(raw_rules):
        if type(raw_rule) is not dict:
            raise ValueError(f"rule {index} must be an object")
        _require_exact_keys(raw_rule, ("host", "role", "action", "addresses"), f"rule {index}")
        host = raw_rule["host"]
        role = raw_rule["role"]
        action = raw_rule["action"]
        addresses = raw_rule["addresses"]
        if not _is_dns_name(host):
            raise ValueError(f"rule {index} host must be a canonical lowercase DNS name")
        if host in rules:
            raise ValueError("policy contains a duplicate host")
        if type(role) is not str or role not in RULE_ROLES:
            raise ValueError(f"rule {index} has an unsupported role")
        if type(action) is not str or action not in {"reject", "relay", "drop"}:
            raise ValueError(f"rule {index} has an unsupported action")
        if type(addresses) is not list or any(type(item) is not str for item in addresses):
            raise ValueError(f"rule {index} addresses must be an array of strings")
        normalized = []
        for address_text in addresses:
            try:
                address = ipaddress.ip_address(address_text)
            except ValueError as exc:
                raise ValueError(f"rule {index} contains an invalid IP address") from exc
            canonical = str(address)
            if not _is_global_unicast_ipv4(address):
                raise ValueError(f"rule {index} addresses must be global-unicast IPv4")
            if canonical != address_text:
                raise ValueError(f"rule {index} addresses must use canonical IP notation")
            if canonical in normalized:
                raise ValueError(f"rule {index} contains a duplicate IP address")
            normalized.append(canonical)
        if action == "reject" and normalized:
            raise ValueError("reject rules must not contain upstream addresses")
        if action in {"relay", "drop"} and not normalized:
            raise ValueError(f"{action} rules require at least one pinned public address")
        rules[host] = ProxyRule(host, role, action, tuple(normalized))

    probes = [rule for rule in rules.values() if rule.role == "probe"]
    if len(probes) != 1 or probes[0].host != PROBE_HOST:
        raise ValueError(f"policy must contain exactly one probe rule for {PROBE_HOST}")
    if profile == "vm006a":
        if len(rules) != 1 or probes[0].action != "reject":
            raise ValueError("vm006a must contain only a rejected probe rule")
    else:
        metadata = [rule for rule in rules.values() if rule.role == "metadata"]
        payload = [rule for rule in rules.values() if rule.role == "payload"]
        if probes[0].action != "relay":
            raise ValueError("vm006b probe rule must relay")
        if not metadata or any(rule.action != "relay" for rule in metadata):
            raise ValueError("vm006b requires at least one relayed metadata host")
        if not payload or any(rule.action != "drop" for rule in payload):
            raise ValueError("vm006b requires at least one dropped payload host")
    return Policy(profile, rules, DROP_AFTER_BYTES, CONNECT_TIMEOUT_SECONDS, digest)


def parse_connect_line(line: bytes) -> Tuple[str, int]:
    try:
        decoded = line.decode("ascii")
        if decoded.endswith("\r\n"):
            decoded = decoded[:-2]
        if "\r" in decoded or "\n" in decoded:
            raise ValueError("request line contains an unexpected line break")
        method, authority, version = decoded.split(" ")
        host, port_text = authority.rsplit(":", 1)
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError("invalid CONNECT request line") from exc
    normalized_host = host.lower().rstrip(".")
    if method != "CONNECT" or version not in {"HTTP/1.0", "HTTP/1.1"}:
        raise ValueError("only CONNECT is supported")
    if (
        not _is_dns_name(normalized_host)
        or any(character in host for character in "/?#@")
        or port_text != "443"
    ):
        raise ValueError("only credential-free HTTPS DNS authorities are supported")
    return normalized_host, 443


class EventLogger:
    def __init__(self, stream: IO[str]) -> None:
        self._stream = stream
        self._lock = threading.Lock()

    def write(self, role: str, event: str, byte_count: int) -> None:
        if role not in LOG_ROLES or event not in LOG_EVENTS:
            raise ValueError("log role or event is outside the fixed schema")
        if type(byte_count) is not int or byte_count < 0:
            raise ValueError("log byte count must be a non-negative integer")
        record = {
            "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
            "role": role,
            "event": event,
            "bytes": byte_count,
        }
        with self._lock:
            self._stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
            self._stream.flush()


def read_header(connection: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(2048)
        if not chunk:
            raise ValueError("connection closed before header")
        data.extend(chunk)
        if len(data) > MAX_HEADER:
            raise ValueError("header exceeds limit")
    return bytes(data)


def relay(client: socket.socket, upstream: socket.socket, byte_limit: Optional[int]) -> int:
    downstream_bytes = 0
    sockets = [client, upstream]
    while True:
        readable, _, exceptional = select.select(sockets, [], sockets, 30)
        if exceptional or not readable:
            return downstream_bytes
        for source in readable:
            target = upstream if source is client else client
            data = source.recv(16 * 1024)
            if not data:
                return downstream_bytes
            if source is upstream:
                if byte_limit is not None:
                    remaining = byte_limit - downstream_bytes
                    if remaining <= 0:
                        return downstream_bytes
                    data = data[:remaining]
                target.sendall(data)
                downstream_bytes += len(data)
                if byte_limit is not None and downstream_bytes == byte_limit:
                    return downstream_bytes
            else:
                target.sendall(data)


def connect_pinned(rule: ProxyRule, timeout: float) -> socket.socket:
    last_error: Optional[OSError] = None
    for address_text in rule.addresses:
        try:
            address = ipaddress.ip_address(address_text)
        except ValueError as exc:
            raise ValueError("policy rule contains an invalid pinned address") from exc
        if not _is_global_unicast_ipv4(address) or str(address) != address_text:
            raise ValueError("policy rule contains an unsafe pinned address")
        candidate: Optional[socket.socket] = None
        try:
            candidate = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            candidate.settimeout(timeout)
            candidate.connect((address_text, 443))
            return candidate
        except OSError as exc:
            if candidate is not None:
                candidate.close()
            last_error = exc
    if last_error is not None:
        raise last_error
    raise ValueError("policy rule has no pinned upstream address")


def handle(connection: socket.socket, address: Tuple[str, int], policy: Policy, logger: EventLogger) -> None:
    client_ip = address[0]
    role = "unknown"
    transferred = 0
    try:
        if ipaddress.ip_address(client_ip) != ALLOWED_CLIENT:
            logger.write(role, "client-rejected", 0)
            return
        connection.settimeout(CLIENT_HEADER_TIMEOUT_SECONDS)
        header = read_header(connection)
        host, _ = parse_connect_line(header.split(b"\r\n", 1)[0])
        connection.settimeout(None)
        rule = policy.rule_for(host)
        if rule is None:
            connection.sendall(b"HTTP/1.1 502 Lab Policy Reject\r\nConnection: close\r\n\r\n")
            logger.write(role, "target-not-allowed", 0)
            return
        role = rule.role
        if rule.action == "reject":
            connection.sendall(b"HTTP/1.1 502 Lab Fault\r\nConnection: close\r\n\r\n")
            logger.write(role, "connect-rejected", 0)
            return
        upstream = connect_pinned(rule, policy.connect_timeout)
        try:
            connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            limit = policy.drop_after_bytes if rule.action == "drop" else None
            transferred = relay(connection, upstream, limit)
            if limit is None:
                event = "relay-closed"
            elif transferred >= limit:
                event = "transfer-dropped"
            else:
                event = "upstream-closed-before-drop"
            logger.write(role, event, transferred)
        finally:
            upstream.close()
    except Exception:  # Never copy exception text or types derived from private input into evidence.
        logger.write(role, "proxy-error", transferred)
    finally:
        connection.close()


def _handle_with_slot(
    connection: socket.socket,
    address: Tuple[str, int],
    policy: Policy,
    logger: EventLogger,
    slots: threading.BoundedSemaphore,
) -> None:
    try:
        handle(connection, address, policy, logger)
    finally:
        slots.release()


def dispatch_connection(
    connection: socket.socket,
    address: Tuple[str, int],
    policy: Policy,
    logger: EventLogger,
    slots: threading.BoundedSemaphore,
) -> bool:
    if not slots.acquire(blocking=False):
        logger.write("unknown", "connection-limit", 0)
        connection.close()
        return False
    try:
        thread = threading.Thread(
            target=_handle_with_slot,
            args=(connection, address, policy, logger, slots),
            daemon=True,
        )
        thread.start()
    except Exception:
        slots.release()
        connection.close()
        logger.write("unknown", "proxy-error", 0)
        raise
    return True


def _assert_create_new_path(path: Path, label: str) -> None:
    if path.exists() or path.is_symlink():
        raise ValueError(f"{label} path already exists")
    if not path.parent.is_dir():
        raise ValueError(f"{label} parent directory does not exist")


def _open_new_private_text(path: Path, label: str) -> IO[str]:
    _assert_create_new_path(path, label)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        os.fchmod(descriptor, 0o600)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"{label} could not be secured as a regular file")
        if hasattr(os, "getuid") and stat.S_IMODE(metadata.st_mode) != 0o600:
            raise ValueError(f"{label} could not be secured as a 0600 regular file")
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            raise ValueError(f"{label} owner does not match the invoking user")
        stream = os.fdopen(descriptor, "w", encoding="utf-8", newline="\n")
        descriptor = -1
        return stream
    except Exception as exc:
        if descriptor >= 0:
            os.close(descriptor)
        if created:
            try:
                path.unlink()
            except OSError:
                pass
        if isinstance(exc, ValueError):
            raise
        raise ValueError(f"{label} could not be created safely") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    policy = load_policy(Path(args.policy))
    log_path = Path(args.log)
    ready_path = Path(args.ready_file)
    _assert_create_new_path(log_path, "log")
    _assert_create_new_path(ready_path, "ready file")

    with socket.create_server((BIND_ADDRESS, BIND_PORT), reuse_port=False) as server:
        with _open_new_private_text(log_path, "log") as log_stream:
            ready = {
                "bind": BIND_ADDRESS,
                "port": BIND_PORT,
                "allowedClient": str(ALLOWED_CLIENT),
                "policyProfile": policy.profile,
                "policySha256": policy.sha256,
            }
            with _open_new_private_text(ready_path, "ready file") as ready_stream:
                ready_stream.write(json.dumps(ready, separators=(",", ":"), sort_keys=True) + "\n")
                ready_stream.flush()
                os.fsync(ready_stream.fileno())
            logger = EventLogger(log_stream)
            slots = threading.BoundedSemaphore(MAX_CONCURRENT_CONNECTIONS)
            while True:
                connection, client_address = server.accept()
                dispatch_connection(connection, client_address, policy, logger, slots)


if __name__ == "__main__":
    sys.exit(main())
