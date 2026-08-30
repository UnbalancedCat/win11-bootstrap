#!/usr/bin/env python3
"""Validate a private Gateway policy and render deterministic nftables rules.

Policy values are intentionally written only to the caller-provided private
rules file.  Standard output contains hashes and counts, never endpoints.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import ipaddress
import json
import os
import re
import stat
import sys
from typing import Any, Dict, Iterable, List, Tuple


PROFILES = {
    "vm004-bootstrap",
    "vm004-subscription",
    "vm004-runtime",
    "vm006",
}
MAX_POLICY_BYTES = 64 * 1024
MAX_ENDPOINTS_PER_LIST = 9999
INTERFACE_PATTERN = re.compile(r"[A-Za-z0-9_.:-]{1,15}\Z")
SUT_ADDRESS = "192.168.77.10"
PROXY_PORT = 7897


class PolicyError(ValueError):
    """A policy or rendering input failed a fail-closed check."""


@dataclasses.dataclass(frozen=True, order=True)
class Endpoint:
    address: str
    protocol: str
    port: int


@dataclasses.dataclass(frozen=True)
class GatewayPolicy:
    profile: str
    blocked: Tuple[Endpoint, ...]
    allowed: Tuple[Endpoint, ...]
    sha256: str


def _object_without_duplicate_keys(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise PolicyError("JSON contains a duplicate object key")
        result[key] = value
    return result


def _read_private_regular_file(path: str) -> bytes:
    if not hasattr(os, "getuid"):
        raise PolicyError("Gateway policies require a POSIX host")
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise PolicyError("policy file cannot be inspected") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise PolicyError("policy must be a regular non-symlink file")
    if before.st_uid != os.getuid():
        raise PolicyError("policy owner must equal the current uid")
    if stat.S_IMODE(before.st_mode) != 0o600:
        raise PolicyError("policy permissions must be exactly 0600")

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise PolicyError("policy file cannot be opened safely") from exc
    try:
        after = os.fstat(descriptor)
        if not stat.S_ISREG(after.st_mode):
            raise PolicyError("opened policy is not a regular file")
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise PolicyError("policy identity changed while opening")
        if after.st_uid != os.getuid() or stat.S_IMODE(after.st_mode) != 0o600:
            raise PolicyError("policy ownership or permissions changed while opening")
        chunks: List[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, 8192)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_POLICY_BYTES:
                raise PolicyError("policy exceeds the size limit")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _require_exact_keys(value: Any, keys: Iterable[str], label: str) -> Dict[str, Any]:
    if type(value) is not dict:
        raise PolicyError(f"{label} must be an object")
    expected = set(keys)
    if set(value) != expected:
        raise PolicyError(f"{label} fields do not match the strict schema")
    return value


def _parse_endpoint(value: Any, label: str) -> Endpoint:
    item = _require_exact_keys(value, ("address", "protocol", "port"), label)
    address_text = item["address"]
    protocol = item["protocol"]
    port = item["port"]
    if type(address_text) is not str:
        raise PolicyError(f"{label} address must be a string")
    try:
        address = ipaddress.ip_address(address_text)
    except ValueError as exc:
        raise PolicyError(f"{label} address must be one exact IP") from exc
    # The lab identifies the only permitted client by its IPv4 source address;
    # accepting IPv6 endpoints would imply an unauthenticated IPv6 client path.
    if (
        address.version != 4
        or not address.is_global
        or address.is_multicast
        or address.is_unspecified
        or address.is_reserved
        or address.is_loopback
        or address.is_link_local
        or address.is_private
        or address_text != str(address)
    ):
        raise PolicyError(f"{label} address must be a canonical global IPv4 address")
    if type(protocol) is not str or protocol not in {"tcp", "udp"}:
        raise PolicyError(f"{label} protocol must be exactly tcp or udp")
    if type(port) is not int or not 1 <= port <= 65535:
        raise PolicyError(f"{label} port must be an exact integer from 1 through 65535")
    return Endpoint(str(address), protocol, port)


def _parse_endpoint_list(value: Any, label: str) -> Tuple[Endpoint, ...]:
    if type(value) is not list:
        raise PolicyError(f"{label} must be an array")
    if len(value) > MAX_ENDPOINTS_PER_LIST:
        raise PolicyError(f"{label} exceeds the endpoint-count limit")
    endpoints = tuple(_parse_endpoint(item, f"{label}[{index}]") for index, item in enumerate(value))
    if len(set(endpoints)) != len(endpoints):
        raise PolicyError(f"{label} contains a duplicate endpoint")
    return tuple(sorted(endpoints))


def load_policy(path: str, expected_profile: str) -> GatewayPolicy:
    if expected_profile not in PROFILES:
        raise PolicyError("unsupported profile")
    raw = _read_private_regular_file(path)
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=_object_without_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PolicyError("policy must be strict UTF-8 JSON") from exc
    root = _require_exact_keys(document, ("schemaVersion", "profile", "blocked", "allowed"), "policy")
    if type(root["schemaVersion"]) is not int or root["schemaVersion"] != 1:
        raise PolicyError("policy schemaVersion must be integer 1")
    if type(root["profile"]) is not str or root["profile"] != expected_profile:
        raise PolicyError("policy profile does not match the requested profile")
    blocked = _parse_endpoint_list(root["blocked"], "blocked")
    allowed = _parse_endpoint_list(root["allowed"], "allowed")
    if not blocked:
        raise PolicyError("blocked must contain at least one endpoint")
    if set(blocked).intersection(allowed):
        raise PolicyError("blocked and allowed endpoints must not overlap")
    if expected_profile == "vm006":
        if allowed:
            raise PolicyError("vm006 must not allow forwarded endpoints")
    elif not allowed:
        raise PolicyError("vm004 profiles require at least one allowed endpoint")
    return GatewayPolicy(
        profile=expected_profile,
        blocked=blocked,
        allowed=allowed,
        sha256=hashlib.sha256(raw).hexdigest(),
    )


def _validate_interfaces(wan_interface: str, lan_interface: str) -> None:
    if not INTERFACE_PATTERN.fullmatch(wan_interface) or not INTERFACE_PATTERN.fullmatch(lan_interface):
        raise PolicyError("interface names must use the restricted Linux interface-name syntax")
    if wan_interface == lan_interface:
        raise PolicyError("WAN and LAN interfaces must differ")


def render_rules(policy: GatewayPolicy, wan_interface: str, lan_interface: str) -> str:
    _validate_interfaces(wan_interface, lan_interface)
    lines = [
        "table inet w11b_lab {",
        "  chain input {",
        "    type filter hook input priority filter; policy accept;",
        f'    iifname "{lan_interface}" meta nfproto ipv6 counter drop comment "w11b-input-ipv6-drop"',
        f'    iifname "{lan_interface}" ip saddr != {SUT_ADDRESS} counter drop comment "w11b-input-non-sut-drop"',
    ]
    if policy.profile == "vm006":
        lines.append(
            f'    iifname "{lan_interface}" ip saddr {SUT_ADDRESS} tcp dport {PROXY_PORT} '
            'counter accept comment "w11b-fault-proxy-input-accept"'
        )
        input_drop_comment = "w11b-fault-proxy-input-drop"
    else:
        input_drop_comment = "w11b-input-sut-drop"
    lines.extend(
        [
            f'    iifname "{lan_interface}" ip saddr {SUT_ADDRESS} counter drop comment "{input_drop_comment}"',
            "  }",
            "  chain forward {",
            "    type filter hook forward priority filter; policy drop;",
            '    ct state invalid counter drop comment "w11b-forward-invalid-drop"',
            f'    iifname "{lan_interface}" meta nfproto ipv6 counter drop comment "w11b-forward-ipv6-drop"',
            f'    iifname "{lan_interface}" ip saddr != {SUT_ADDRESS} counter drop comment "w11b-forward-non-sut-drop"',
        ]
    )
    for index, endpoint in enumerate(policy.blocked, start=1):
        lines.append(
            f'    iifname "{lan_interface}" oifname "{wan_interface}" '
            f"ip saddr {SUT_ADDRESS} ip daddr {endpoint.address} "
            f'{endpoint.protocol} dport {endpoint.port} counter drop comment "w11b-blocked-target-{index:04d}"'
        )
    for index, endpoint in enumerate(policy.allowed, start=1):
        lines.append(
            f'    iifname "{lan_interface}" oifname "{wan_interface}" '
            f"ip saddr {SUT_ADDRESS} ip daddr {endpoint.address} "
            f'{endpoint.protocol} dport {endpoint.port} ct state new,established counter accept '
            f'comment "w11b-allowed-forward-{index:04d}"'
        )
    if policy.profile == "vm006":
        lines.append(
            f'    iifname "{lan_interface}" ip saddr {SUT_ADDRESS} '
            'counter drop comment "w11b-forward-all-sut-drop"'
        )
    lines.extend(
        [
            f'    iifname "{wan_interface}" oifname "{lan_interface}" '
            f'ip daddr {SUT_ADDRESS} ct state established,related counter accept '
            'comment "w11b-return-established-accept"',
            '    counter drop comment "w11b-forward-default-drop"',
            "  }",
            "}",
            "table ip w11b_lab_nat {",
            "  chain postrouting {",
            "    type nat hook postrouting priority srcnat; policy accept;",
            f'    oifname "{wan_interface}" ip saddr {SUT_ADDRESS} '
            'counter masquerade comment "w11b-masquerade"',
            "  }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def _write_new_private_file(path: str, content: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(content):
            offset += os.write(descriptor, content[offset:])
        os.fsync(descriptor)
    except OSError as exc:
        if created:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise PolicyError("private rules output could not be created") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--wan-if", required=True)
    parser.add_argument("--lan-if", required=True)
    parser.add_argument("--rules-output", required=True)
    args = parser.parse_args(argv)
    try:
        policy = load_policy(args.policy, args.profile)
        rules = render_rules(policy, args.wan_if, args.lan_if)
        encoded_rules = rules.encode("utf-8")
        _write_new_private_file(args.rules_output, encoded_rules)
    except PolicyError as exc:
        print(f"Gateway policy rejected: {exc}", file=sys.stderr)
        return 64
    print(
        " ".join(
            (
                f"policySha256={policy.sha256}",
                f"rulesSha256={hashlib.sha256(encoded_rules).hexdigest()}",
                f"blockedCount={len(policy.blocked)}",
                f"allowedCount={len(policy.allowed)}",
            )
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
