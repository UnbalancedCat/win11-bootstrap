#!/usr/bin/env python3
"""Capture a redacted, fail-closed identity snapshot of the Ubuntu Gateway."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import types
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


IP = "/usr/sbin/ip"
NFT = "/usr/sbin/nft"
SYSCTL = "/usr/sbin/sysctl"
SS = "/usr/bin/ss"
UNAME = "/usr/bin/uname"
IPTABLES_SAVE = "/usr/sbin/iptables-save"
IP6TABLES_SAVE = "/usr/sbin/ip6tables-save"
OS_RELEASE = "/usr/lib/os-release"
FIXED_EXECUTABLES = frozenset((IP, NFT, SYSCTL, SS, UNAME, IPTABLES_SAVE, IP6TABLES_SAVE))
FIXTURE_FILE_ALLOWLIST = (
    "capture_gateway_state.py",
    "configure_gateway.sh",
    "fault_proxy.py",
    "gateway_policy.py",
)
PROFILES = frozenset(("vm004-bootstrap", "vm004-subscription", "vm004-runtime", "vm006"))
INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$")
SAFE_OS_VALUE = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")
SAFE_KERNEL_VALUE = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
PROCESS_USERS = re.compile(r'^users:\(\("python3",pid=([1-9][0-9]*),fd=[0-9]+\)\)$')
PYTHON_EXE = re.compile(r"^/usr/bin/python3(?:\.[0-9]+)?$")
LAB_ADDRESS = "192.168.77.1"
LAB_PREFIX_LENGTH = 24
SUT_ADDRESS = "192.168.77.10"
PROXY_PORT = 7897
LISTENER_ENDPOINT = f"{LAB_ADDRESS}:{PROXY_PORT}"
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_POLICY_BYTES = 64 * 1024
MAX_READY_BYTES = 64 * 1024
MAX_COMMAND_BYTES = 16 * 1024 * 1024

Runner = Callable[[Tuple[str, ...]], bytes]
ProcessInspector = Callable[[int, str, str, Mapping[str, object]], Mapping[str, object]]


class CaptureError(RuntimeError):
    """A fail-closed capture or parsing check failed."""


def _load_frozen_sibling(name: str):
    """Reject the obsolete path-based loader; modules require verified bound bytes."""

    raise CaptureError(f"path-based fixture module loading is forbidden: {name}")


@dataclasses.dataclass
class FixtureContext:
    root_path: str
    root_fd: Optional[int]
    identity: Mapping[str, object]
    files: Mapping[str, bytes]
    gateway_policy: Any
    fault_proxy: Any
    production_trusted: bool

    def close(self) -> None:
        if self.root_fd is not None:
            os.close(self.root_fd)
            self.root_fd = None


def _require_posix_security() -> None:
    required = ("geteuid", "O_NOFOLLOW", "O_DIRECTORY", "O_CLOEXEC")
    if os.name != "posix" or any(not hasattr(os, name) for name in required):
        raise CaptureError("POSIX no-follow security primitives are required")


def _require_production_root() -> None:
    _require_posix_security()
    if os.geteuid() != 0:
        raise CaptureError("production Gateway capture requires EUID 0")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def _canonical_hash(value: object) -> str:
    return _sha256(_canonical_bytes(value))


def _object_without_duplicate_keys(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CaptureError("JSON contains a duplicate object key")
        result[key] = value
    return result


def _json_output(data: bytes, label: str) -> object:
    try:
        return json.loads(
            data.decode("utf-8", errors="strict"),
            object_pairs_hook=_object_without_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, CaptureError) as exc:
        raise CaptureError(f"{label} did not return strict JSON") from exc


def _read_fd(fd: int, maximum: int) -> bytes:
    data = bytearray()
    while True:
        remaining = maximum + 1 - len(data)
        if remaining <= 0:
            raise CaptureError("trusted input exceeds its size limit")
        chunk = os.read(fd, min(65536, remaining))
        if not chunk:
            return bytes(data)
        data.extend(chunk)
        if len(data) > maximum:
            raise CaptureError("trusted input exceeds its size limit")


def _validate_owned_stat(
    value: os.stat_result,
    *,
    exact_mode: Optional[int] = None,
    directory: bool = False,
    expected_uid: Optional[int] = None,
) -> None:
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(value.st_mode):
        raise CaptureError("trusted object has the wrong file type")
    owner = os.geteuid() if expected_uid is None else expected_uid
    if value.st_uid != owner:
        raise CaptureError("trusted object owner does not match the required uid")
    mode = stat.S_IMODE(value.st_mode)
    if exact_mode is not None:
        if mode != exact_mode:
            raise CaptureError("trusted object mode is not exact")
    elif mode & 0o022:
        raise CaptureError("trusted object is writable by group or other")


def _normalized_absolute_path(path: str, label: str) -> str:
    if not isinstance(path, str) or not path or "\0" in path or not os.path.isabs(path):
        raise CaptureError(f"{label} must be an absolute path")
    normalized = os.path.normpath(path)
    if normalized != path:
        raise CaptureError(f"{label} must use normalized absolute spelling")
    return normalized


def _open_trusted_directory_chain(path: str, *, expected_uid: int = 0) -> int:
    """Open and validate every directory from / through path, returning the final dirfd."""

    _require_posix_security()
    absolute = _normalized_absolute_path(path, "trusted directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        current_fd = os.open(os.sep, flags)
    except OSError as exc:
        raise CaptureError("filesystem root cannot be opened safely") from exc
    try:
        _validate_owned_stat(os.fstat(current_fd), directory=True, expected_uid=expected_uid)
        for component in (part for part in absolute.split(os.sep) if part):
            if component in (".", ".."):
                raise CaptureError("trusted directory traversal is invalid")
            try:
                next_fd = os.open(component, flags, dir_fd=current_fd)
            except OSError as exc:
                raise CaptureError("trusted directory chain contains an unsafe component") from exc
            try:
                _validate_owned_stat(os.fstat(next_fd), directory=True, expected_uid=expected_uid)
            except Exception:
                os.close(next_fd)
                raise
            os.close(current_fd)
            current_fd = next_fd
        return current_fd
    except Exception:
        os.close(current_fd)
        raise


def _read_private_regular(path: str, maximum: int, label: str) -> bytes:
    _require_posix_security()
    absolute = os.path.abspath(path)
    try:
        before = os.lstat(absolute)
    except OSError as exc:
        raise CaptureError(f"{label} cannot be inspected") from exc
    if stat.S_ISLNK(before.st_mode):
        raise CaptureError(f"{label} must not be a symbolic link")
    _validate_owned_stat(before, exact_mode=0o600)
    try:
        fd = os.open(absolute, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as exc:
        raise CaptureError(f"{label} cannot be opened safely") from exc
    try:
        opened = os.fstat(fd)
        _validate_owned_stat(opened, exact_mode=0o600)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise CaptureError(f"{label} identity changed while opening")
        return _read_fd(fd, maximum)
    finally:
        os.close(fd)


def _read_fixture_files(root_fd: int, *, expected_uid: int) -> Mapping[str, bytes]:
    files: Dict[str, bytes] = {}
    for name in FIXTURE_FILE_ALLOWLIST:
        try:
            item_before = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        except OSError as exc:
            raise CaptureError("allowlisted fixture file cannot be inspected") from exc
        if stat.S_ISLNK(item_before.st_mode):
            raise CaptureError("allowlisted fixture file must not be a symlink")
        _validate_owned_stat(item_before, expected_uid=expected_uid)
        try:
            item_fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=root_fd)
        except OSError as exc:
            raise CaptureError("allowlisted fixture file cannot be opened safely") from exc
        try:
            item_opened = os.fstat(item_fd)
            _validate_owned_stat(item_opened, expected_uid=expected_uid)
            if (item_before.st_dev, item_before.st_ino) != (item_opened.st_dev, item_opened.st_ino):
                raise CaptureError("allowlisted fixture file changed while opening")
            files[name] = _read_fd(item_fd, MAX_FILE_BYTES)
        finally:
            os.close(item_fd)
    return files


def _fixture_identity_from_bytes(files: Mapping[str, bytes]) -> Mapping[str, object]:
    if set(files) != set(FIXTURE_FILE_ALLOWLIST):
        raise CaptureError("fixture byte inventory does not match the allowlist")
    hasher = hashlib.sha256()
    hasher.update(b"w11b-gateway-fixture-v1\0")
    total_size = 0
    for name in FIXTURE_FILE_ALLOWLIST:
        data = files[name]
        encoded_name = name.encode("ascii")
        hasher.update(len(encoded_name).to_bytes(4, "big"))
        hasher.update(encoded_name)
        hasher.update(len(data).to_bytes(8, "big"))
        hasher.update(data)
        total_size += len(data)
    return {"sha256": hasher.hexdigest(), "size": total_size, "fileCount": len(FIXTURE_FILE_ALLOWLIST)}


def _module_from_verified_bytes(name: str, data: bytes, display_path: str) -> types.ModuleType:
    module_name = f"_w11b_frozen_{name}_{_sha256(data)[:16]}"
    try:
        source = data.decode("utf-8", errors="strict")
        code = compile(source, display_path, "exec", dont_inherit=True)
    except (UnicodeDecodeError, SyntaxError, ValueError) as exc:
        raise CaptureError("verified fixture module cannot be compiled") from exc
    module = types.ModuleType(module_name)
    module.__file__ = display_path
    module.__package__ = ""
    previous = sys.modules.get(module_name)
    sys.modules[module_name] = module
    try:
        exec(code, module.__dict__)
    except Exception as exc:
        raise CaptureError("verified fixture module failed during initialization") from exc
    finally:
        if previous is None:
            sys.modules.pop(module_name, None)
        else:
            sys.modules[module_name] = previous
    return module


def _modules_from_verified_fixture(files: Mapping[str, bytes], root_path: str) -> Tuple[Any, Any]:
    policy_module = _module_from_verified_bytes(
        "gateway_policy", files["gateway_policy.py"], os.path.join(root_path, "gateway_policy.py")
    )
    proxy_module = _module_from_verified_bytes(
        "fault_proxy", files["fault_proxy.py"], os.path.join(root_path, "fault_proxy.py")
    )
    try:
        mismatch = (
            frozenset(getattr(policy_module, "PROFILES", ())) != PROFILES
            or getattr(policy_module, "SUT_ADDRESS", None) != SUT_ADDRESS
            or getattr(policy_module, "PROXY_PORT", None) != PROXY_PORT
            or getattr(proxy_module, "BIND_ADDRESS", None) != LAB_ADDRESS
            or getattr(proxy_module, "BIND_PORT", None) != PROXY_PORT
            or str(getattr(proxy_module, "ALLOWED_CLIENT", "")) != SUT_ADDRESS
        )
    except Exception as exc:
        raise CaptureError("verified fixture module constants are invalid") from exc
    if mismatch:
        raise CaptureError("verified fixture module constants differ from the frozen contract")
    return policy_module, proxy_module


def _load_production_fixture_context(root: str) -> FixtureContext:
    _require_production_root()
    root_path = _normalized_absolute_path(root, "fixture root")
    root_fd = _open_trusted_directory_chain(root_path, expected_uid=0)
    return _fixture_context_from_open_fd(root_path, root_fd, expected_uid=0, production_trusted=True)


def _fixture_context_from_open_fd(
    root_path: str,
    root_fd: int,
    *,
    expected_uid: int,
    production_trusted: bool,
) -> FixtureContext:
    """Consume a validated directory fd and bind modules and identity to its verified bytes."""

    try:
        _validate_owned_stat(
            os.fstat(root_fd), directory=True, expected_uid=expected_uid
        )
        files = _read_fixture_files(root_fd, expected_uid=expected_uid)
        identity = _fixture_identity_from_bytes(files)
        policy_module, proxy_module = _modules_from_verified_fixture(files, root_path)
        return FixtureContext(
            root_path,
            root_fd,
            identity,
            files,
            policy_module,
            proxy_module,
            production_trusted,
        )
    except Exception:
        os.close(root_fd)
        raise


def _unit_fixture_context(
    root: str,
    files: Mapping[str, bytes],
    policy_module: Any,
    proxy_module: Any,
) -> FixtureContext:
    """Build a non-production dependency injection used only with an injected command runner."""

    return FixtureContext(
        os.path.abspath(root),
        None,
        _fixture_identity_from_bytes(files),
        dict(files),
        policy_module,
        proxy_module,
        False,
    )


def _production_runner(argv: Tuple[str, ...]) -> bytes:
    if not argv or argv[0] not in FIXED_EXECUTABLES or not os.path.isabs(argv[0]):
        raise CaptureError("command executable is not allowlisted")
    try:
        completed = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            shell=False,
            check=False,
            timeout=20,
            env={"LANG": "C", "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CaptureError("fixed read-only command could not run") from exc
    if completed.returncode != 0 or len(completed.stdout) > MAX_COMMAND_BYTES:
        raise CaptureError("fixed read-only command failed or returned too much output")
    return completed.stdout


def _invoke(runner: Runner, argv: Sequence[str]) -> bytes:
    command = tuple(argv)
    if not command or command[0] not in FIXED_EXECUTABLES or not os.path.isabs(command[0]):
        raise CaptureError("command executable is not allowlisted")
    try:
        output = runner(command)
    except CaptureError:
        raise
    except Exception as exc:
        raise CaptureError("injected read-only command failed") from exc
    if not isinstance(output, bytes) or len(output) > MAX_COMMAND_BYTES:
        raise CaptureError("command runner returned invalid output")
    return output


def _short_text(value: object, label: str, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or any(ord(ch) < 32 for ch in value):
        raise CaptureError(f"{label} contains invalid text")
    return value


def _nonnegative_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CaptureError(f"{label} must be a nonnegative integer")
    return value


def _load_network_policy(path: str, profile: str, policy_module: Any) -> Tuple[Any, Mapping[str, object]]:
    if profile not in PROFILES:
        raise CaptureError("unsupported Gateway profile")
    raw = _read_private_regular(path, MAX_POLICY_BYTES, "policy")
    digest = _sha256(raw)
    try:
        parsed = policy_module.load_policy(path, profile)
    except policy_module.PolicyError as exc:
        raise CaptureError("Gateway policy failed strict validation") from exc
    if parsed.sha256 != digest:
        raise CaptureError("Gateway policy identity changed while validating")
    return parsed, {
        "sha256": digest,
        "size": len(raw),
        "mode": "0600",
        "profile": parsed.profile,
        "blockedCount": len(parsed.blocked),
        "allowedCount": len(parsed.allowed),
    }


def _parse_links(data: bytes, names: Mapping[str, str]) -> Tuple[Mapping[str, object], List[object]]:
    document = _json_output(data, "all links")
    if not isinstance(document, list):
        raise CaptureError("all-link output must be a list")
    roles = {name: role for role, name in names.items()}
    found: Dict[str, object] = {}
    normalized: List[object] = []
    for raw in document:
        if not isinstance(raw, dict):
            raise CaptureError("all-link output contains a non-object")
        name = _short_text(raw.get("ifname"), "link interface", 15)
        if name not in roles or name in found:
            raise CaptureError("Gateway must expose only unique lo, WAN, and LAN links")
        flags = raw.get("flags")
        if not isinstance(flags, list) or any(not isinstance(item, str) for item in flags):
            raise CaptureError("link flags have an invalid shape")
        mtu = _nonnegative_int(raw.get("mtu"), "link mtu")
        raw_address = raw.get("address", "")
        address = "" if raw_address == "" else _short_text(raw_address, "link address", 64).lower()
        if address and not re.fullmatch(r"[0-9a-f:.-]+", address):
            raise CaptureError("link address has an invalid shape")
        found[name] = {"up": "UP" in flags, "mtu": mtu, "macSha256": _sha256(address.encode("ascii"))}
        normalized.append({"role": roles[name], "flags": sorted(flags), "mtu": mtu, "address": address})
    if set(found) != set(roles):
        raise CaptureError("Gateway is missing lo, WAN, or LAN")
    return found, sorted(normalized, key=_canonical_bytes)


def _parse_addresses(data: bytes, names: Mapping[str, str]) -> Tuple[Mapping[str, object], List[object]]:
    document = _json_output(data, "all addresses")
    if not isinstance(document, list):
        raise CaptureError("all-address output must be a list")
    roles = {name: role for role, name in names.items()}
    found: Dict[str, object] = {}
    all_records: List[object] = []
    for raw_interface in document:
        if not isinstance(raw_interface, dict):
            raise CaptureError("all-address output contains a non-object")
        name = _short_text(raw_interface.get("ifname"), "address interface", 15)
        if name not in roles or name in found:
            raise CaptureError("addresses refer to an unexpected or duplicate interface")
        raw_addresses = raw_interface.get("addr_info", [])
        if not isinstance(raw_addresses, list):
            raise CaptureError("address output has an invalid shape")
        records: List[object] = []
        v4 = v6 = global_v6 = 0
        lab_present = False
        for raw in raw_addresses:
            if not isinstance(raw, dict) or raw.get("family") not in ("inet", "inet6"):
                if isinstance(raw, dict):
                    continue
                raise CaptureError("address output contains a non-object")
            family = raw["family"]
            text = _short_text(raw.get("local"), "address")
            try:
                address = ipaddress.ip_address(text)
            except ValueError as exc:
                raise CaptureError("address is invalid") from exc
            if (family == "inet") != (address.version == 4) or text != str(address):
                raise CaptureError("address family or spelling is invalid")
            prefix = _nonnegative_int(raw.get("prefixlen"), "address prefix")
            if prefix > (32 if address.version == 4 else 128):
                raise CaptureError("address prefix is invalid")
            scope = _short_text(raw.get("scope", "unknown"), "address scope")
            record = {
                "role": roles[name],
                "family": family,
                "address": text,
                "prefixLength": prefix,
                "scope": scope,
            }
            records.append(record)
            all_records.append(record)
            if family == "inet":
                v4 += 1
                lab_present |= roles[name] == "lan" and text == LAB_ADDRESS and prefix == LAB_PREFIX_LENGTH
            else:
                v6 += 1
                global_v6 += scope == "global"
        records.sort(key=_canonical_bytes)
        summary: Dict[str, object] = {
            "sha256": _canonical_hash(records),
            "count": len(records),
            "ipv4Count": v4,
            "ipv6Count": v6,
            "globalIpv6Count": global_v6,
        }
        if roles[name] == "lan":
            summary["labIpv4AddressPresent"] = lab_present
        found[name] = summary
    if set(found) != set(roles):
        raise CaptureError("address inventory is missing lo, WAN, or LAN")
    if not found[names["lan"]]["labIpv4AddressPresent"] or found[names["lan"]]["ipv4Count"] != 1:
        raise CaptureError("LAN must have exactly the fixed lab IPv4 address")
    if found[names["wan"]]["ipv4Count"] < 1:
        raise CaptureError("WAN must have an IPv4 address")
    return found, sorted(all_records, key=_canonical_bytes)


def _route_table(value: object) -> str:
    aliases = {253: "default", 254: "main", 255: "local", "253": "default", "254": "main", "255": "local"}
    normalized = aliases.get(value, value)
    if normalized not in ("default", "main", "local"):
        raise CaptureError("route uses a nonstandard table")
    return str(normalized)


def _parse_ipv6_kernel_guard(raw: Mapping[str, object], family: str) -> Optional[Mapping[str, object]]:
    if raw.get("table") != "unspec":
        return None
    if (
        family != "inet6"
        or raw.get("type") != "unreachable"
        or raw.get("dst") != "default"
        or raw.get("protocol") != "kernel"
        or type(raw.get("metric")) is not int
        or raw.get("metric") != 4294967295
        or "gateway" in raw
        or "multipath" in raw
        or ("dev" in raw and raw["dev"] != "lo")
    ):
        raise CaptureError("unspec route is not the exact IPv6 kernel guard")
    return {
        "type": "unreachable",
        "destination": "default",
        "table": "unspec",
        "protocol": "kernel",
        "metric": 4294967295,
        "device": "loopback" if "dev" in raw else "omitted",
    }


def _parse_routes(
    data: bytes,
    family: str,
    names: Mapping[str, str],
) -> Tuple[Mapping[str, List[object]], List[object], List[object]]:
    document = _json_output(data, f"{family} all-table routes")
    if not isinstance(document, list):
        raise CaptureError("route output must be a list")
    roles = {name: role for role, name in names.items()}
    found: Dict[str, List[object]] = {name: [] for name in roles}
    all_records: List[object] = []
    kernel_guards: List[object] = []
    for raw in document:
        if not isinstance(raw, dict):
            raise CaptureError("route output contains a non-object")
        guard = _parse_ipv6_kernel_guard(raw, family)
        if guard is not None:
            kernel_guards.append(guard)
            continue
        if raw.get("dev") not in roles:
            raise CaptureError("route uses an unexpected or missing interface")
        name = raw["dev"]
        gateway = raw.get("gateway", "")
        record = {
            "role": roles[name],
            "family": family,
            "destination": _short_text(raw.get("dst", "default"), "route destination"),
            "gateway": "" if gateway == "" else _short_text(gateway, "route gateway"),
            "table": _route_table(raw.get("table", "main")),
            "protocol": _short_text(raw.get("protocol", "unknown"), "route protocol"),
            "scope": _short_text(raw.get("scope", "global"), "route scope"),
            "type": _short_text(raw.get("type", "unicast"), "route type"),
            "metric": _nonnegative_int(raw.get("metric", 0), "route metric"),
        }
        found[name].append(record)
        all_records.append(record)
    for records in found.values():
        records.sort(key=_canonical_bytes)
    return (
        found,
        sorted(all_records, key=_canonical_bytes),
        sorted(kernel_guards, key=_canonical_bytes),
    )


def _strict_policy_rules(data: bytes, family: str) -> Mapping[str, object]:
    document = _json_output(data, f"{family} policy rules")
    if not isinstance(document, list):
        raise CaptureError("policy-rule output must be a list")
    normalized = []
    for raw in document:
        if not isinstance(raw, dict) or set(raw).difference({"priority", "src", "table", "protocol"}):
            raise CaptureError("policy rule contains a nonstandard selector")
        item = {
            "priority": _nonnegative_int(raw.get("priority"), "policy-rule priority"),
            "source": raw.get("src"),
            "table": _route_table(raw.get("table")),
        }
        if item["source"] != "all" or raw.get("protocol", "kernel") != "kernel":
            raise CaptureError("policy rule is not a standard kernel rule")
        normalized.append(item)
    if family == "inet":
        expected = ((0, "local"), (32766, "main"), (32767, "default"))
    elif family == "inet6":
        expected = ((0, "local"), (32766, "main"))
    else:
        raise CaptureError("policy-rule family is unsupported")
    if tuple((item["priority"], item["table"]) for item in normalized) != expected:
        raise CaptureError("policy rules differ from local/main/default")
    return {"sha256": _canonical_hash(normalized), "count": len(normalized)}


def _route_identity(records: List[object], family: str) -> Mapping[str, object]:
    defaults = sum(1 for item in records if item["destination"] in ("default", "0.0.0.0/0", "::/0"))
    global_v6 = 0
    if family == "inet6":
        global_v6 = sum(
            1
            for item in records
            if item["destination"] not in ("default", "::/0")
            and item["scope"] not in ("link", "host", "nowhere")
            and not str(item["destination"]).lower().startswith(("fe80:", "ff", "::1/"))
        )
    return {
        "sha256": _canonical_hash(records),
        "count": len(records),
        "defaultCount": defaults,
        "globalIpv6Count": global_v6,
    }


def _network_topology(runner: Runner, wan: str, lan: str) -> Mapping[str, object]:
    names = {"loopback": "lo", "wan": wan, "lan": lan}
    links, all_links = _parse_links(_invoke(runner, (IP, "-j", "-details", "link", "show")), names)
    addresses, all_addresses = _parse_addresses(_invoke(runner, (IP, "-j", "address", "show")), names)
    routes4, all_routes4, guards4 = _parse_routes(
        _invoke(runner, (IP, "-j", "-4", "route", "show", "table", "all")), "inet", names
    )
    routes6, all_routes6, ipv6_kernel_guards = _parse_routes(
        _invoke(runner, (IP, "-j", "-6", "route", "show", "table", "all")), "inet6", names
    )
    if guards4:
        raise CaptureError("IPv4 must not expose an IPv6 kernel guard")
    rules4 = _strict_policy_rules(_invoke(runner, (IP, "-j", "-4", "rule", "show")), "inet")
    rules6 = _strict_policy_rules(_invoke(runner, (IP, "-j", "-6", "rule", "show")), "inet6")
    identities = {
        (role, family): _route_identity((routes4 if family == "inet" else routes6)[name], family)
        for role, name in names.items()
        for family in ("inet", "inet6")
    }
    if identities[("wan", "inet")]["defaultCount"] != 1:
        raise CaptureError("WAN must expose exactly one IPv4 default route")
    if any(
        identities[(role, family)]["defaultCount"]
        for role in ("lan", "loopback")
        for family in ("inet", "inet6")
    ):
        raise CaptureError("LAN and loopback must not expose default routes")
    summaries: Dict[str, object] = {}
    for role, name in (("wan", wan), ("lan", lan)):
        summary = dict(links[name])
        summary["addresses"] = addresses[name]
        summary["ipv4Routes"] = identities[(role, "inet")]
        summary["ipv6Routes"] = identities[(role, "inet6")]
        summaries[role] = summary
    inventory = {
        "links": all_links,
        "addresses": all_addresses,
        "ipv4Routes": all_routes4,
        "ipv6Routes": all_routes6,
        "ipv6KernelGuards": ipv6_kernel_guards,
        "ipv4Rules": rules4["sha256"],
        "ipv6Rules": rules6["sha256"],
    }
    return {
        "sha256": _canonical_hash(inventory),
        "linkCount": len(all_links),
        "addressCount": len(all_addresses),
        "ipv4RouteCount": len(all_routes4),
        "ipv6RouteCount": len(all_routes6),
        "ipv6KernelGuards": {
            "sha256": _canonical_hash(ipv6_kernel_guards),
            "count": len(ipv6_kernel_guards),
        },
        "policyRules": {"ipv4": rules4, "ipv6": rules6},
        "interfaces": summaries,
    }


def _sysctl_bit(runner: Runner, name: str) -> int:
    try:
        value = _invoke(runner, (SYSCTL, "-n", name)).decode("ascii", errors="strict").strip()
    except UnicodeDecodeError as exc:
        raise CaptureError("sysctl returned non-ASCII output") from exc
    if value not in ("0", "1"):
        raise CaptureError("sysctl did not return a bit")
    return int(value)


def _match(left: Mapping[str, object], right: object, op: str = "==") -> Mapping[str, object]:
    return {"match": {"op": op, "left": left, "right": right}}


def _meta(key: str) -> Mapping[str, object]:
    return {"meta": {"key": key}}


def _payload(protocol: str, field: str) -> Mapping[str, object]:
    return {"payload": {"protocol": protocol, "field": field}}


def _ct(key: str) -> Mapping[str, object]:
    return {"ct": {"key": key}}


def _rule(
    family: str,
    table: str,
    chain: str,
    comment: str,
    matches: Sequence[Mapping[str, object]],
    verdict: str,
) -> Mapping[str, object]:
    return {
        "family": family,
        "table": table,
        "chain": chain,
        "comment": comment,
        "expr": [*matches, {"counter": {}}, {verdict: None}],
    }


def _expected_nft_rules(policy: Any, wan: str, lan: str) -> List[Mapping[str, object]]:
    lan_in = _match(_meta("iifname"), lan)
    wan_in = _match(_meta("iifname"), wan)
    lan_out = _match(_meta("oifname"), lan)
    wan_out = _match(_meta("oifname"), wan)
    sut_source = _match(_payload("ip", "saddr"), SUT_ADDRESS)
    non_sut = _match(_payload("ip", "saddr"), SUT_ADDRESS, "!=")
    sut_destination = _match(_payload("ip", "daddr"), SUT_ADDRESS)
    rules: List[Mapping[str, object]] = [
        _rule("inet", "w11b_lab", "input", "w11b-input-ipv6-drop", (lan_in, _match(_meta("nfproto"), "ipv6")), "drop"),
        _rule("inet", "w11b_lab", "input", "w11b-input-non-sut-drop", (lan_in, non_sut), "drop"),
    ]
    if policy.profile == "vm006":
        rules.append(
            _rule(
                "inet",
                "w11b_lab",
                "input",
                "w11b-fault-proxy-input-accept",
                (lan_in, sut_source, _match(_payload("tcp", "dport"), PROXY_PORT)),
                "accept",
            )
        )
        input_drop = "w11b-fault-proxy-input-drop"
    else:
        input_drop = "w11b-input-sut-drop"
    rules.append(_rule("inet", "w11b_lab", "input", input_drop, (lan_in, sut_source), "drop"))
    rules.extend(
        (
            _rule("inet", "w11b_lab", "forward", "w11b-forward-invalid-drop", (_match(_ct("state"), "invalid"),), "drop"),
            _rule("inet", "w11b_lab", "forward", "w11b-forward-ipv6-drop", (lan_in, _match(_meta("nfproto"), "ipv6")), "drop"),
            _rule("inet", "w11b_lab", "forward", "w11b-forward-non-sut-drop", (lan_in, non_sut), "drop"),
        )
    )
    for index, endpoint in enumerate(policy.blocked, start=1):
        rules.append(
            _rule(
                "inet", "w11b_lab", "forward", f"w11b-blocked-target-{index:04d}",
                (
                    lan_in, wan_out, sut_source,
                    _match(_payload("ip", "daddr"), endpoint.address),
                    _match(_payload(endpoint.protocol, "dport"), endpoint.port),
                ),
                "drop",
            )
        )
    for index, endpoint in enumerate(policy.allowed, start=1):
        rules.append(
            _rule(
                "inet", "w11b_lab", "forward", f"w11b-allowed-forward-{index:04d}",
                (
                    lan_in, wan_out, sut_source,
                    _match(_payload("ip", "daddr"), endpoint.address),
                    _match(_payload(endpoint.protocol, "dport"), endpoint.port),
                    _match(_ct("state"), {"set": ["new", "established"]}),
                ),
                "accept",
            )
        )
    if policy.profile == "vm006":
        rules.append(_rule("inet", "w11b_lab", "forward", "w11b-forward-all-sut-drop", (lan_in, sut_source), "drop"))
    rules.extend(
        (
            _rule(
                "inet", "w11b_lab", "forward", "w11b-return-established-accept",
                (wan_in, lan_out, sut_destination, _match(_ct("state"), {"set": ["established", "related"]})),
                "accept",
            ),
            _rule("inet", "w11b_lab", "forward", "w11b-forward-default-drop", (), "drop"),
            _rule("ip", "w11b_lab_nat", "postrouting", "w11b-masquerade", (wan_out, sut_source), "masquerade"),
        )
    )
    return rules


def _normalize_expression(value: object, *, expected: bool = False) -> object:
    if isinstance(value, list):
        return [_normalize_expression(item, expected=expected) for item in value]
    if isinstance(value, dict):
        if set(value) == {"counter"}:
            counter = value["counter"]
            if expected and counter == {}:
                return {"counter": {}}
            if not isinstance(counter, dict) or set(counter) != {"packets", "bytes"}:
                raise CaptureError("nft counter has an invalid shape")
            _nonnegative_int(counter["packets"], "nft packet counter")
            _nonnegative_int(counter["bytes"], "nft byte counter")
            return {"counter": {}}
        normalized = {key: _normalize_expression(item, expected=expected) for key, item in value.items()}
        if set(normalized) == {"set"}:
            members = normalized["set"]
            if not isinstance(members, list):
                raise CaptureError("nft set has an invalid shape")
            normalized["set"] = sorted(members, key=_canonical_bytes)
        return normalized
    if value is None or isinstance(value, (str, int)):
        return value
    raise CaptureError("nft expression contains an unsupported value")


def _nft_identity(data: bytes, expected_rules: Sequence[Mapping[str, object]]) -> Mapping[str, object]:
    document = _json_output(data, "nft")
    if not isinstance(document, dict) or set(document) != {"nftables"} or not isinstance(document["nftables"], list):
        raise CaptureError("nft output has an invalid root shape")
    expected_tables = {("inet", "w11b_lab"), ("ip", "w11b_lab_nat")}
    expected_chains = {
        ("inet", "w11b_lab", "input"): ("filter", "input", 0, "accept"),
        ("inet", "w11b_lab", "forward"): ("filter", "forward", 0, "drop"),
        ("ip", "w11b_lab_nat", "postrouting"): ("nat", "postrouting", 100, "accept"),
    }
    by_comment = {str(item["comment"]): item for item in expected_rules}
    expected_order: Dict[Tuple[str, str, str], List[str]] = {key: [] for key in expected_chains}
    for item in expected_rules:
        expected_order[(item["family"], item["table"], item["chain"])].append(item["comment"])
    observed_order: Dict[Tuple[str, str, str], List[str]] = {key: [] for key in expected_chains}
    tables = set()
    chains = set()
    counters: Dict[str, object] = {}
    structure: List[object] = []
    metainfo = 0
    for entry in document["nftables"]:
        if not isinstance(entry, dict) or len(entry) != 1:
            raise CaptureError("nft entry has an invalid shape")
        kind, value = next(iter(entry.items()))
        if kind == "metainfo":
            if not isinstance(value, dict) or metainfo:
                raise CaptureError("nft metainfo is invalid or duplicated")
            metainfo += 1
            continue
        if not isinstance(value, dict):
            raise CaptureError("nft entity has an invalid shape")
        if kind == "table":
            if set(value).difference({"family", "name", "handle"}):
                raise CaptureError("nft table contains unexpected attributes")
            identity = (value.get("family"), value.get("name"))
            if identity not in expected_tables or identity in tables:
                raise CaptureError("nft table is unexpected or duplicated")
            tables.add(identity)
            structure.append({"table": list(identity)})
            continue
        if kind == "chain":
            if set(value).difference({"family", "table", "name", "handle", "type", "hook", "prio", "policy"}):
                raise CaptureError("nft chain contains unexpected attributes")
            identity = (value.get("family"), value.get("table"), value.get("name"))
            semantics = (value.get("type"), value.get("hook"), value.get("prio"), value.get("policy"))
            if identity not in expected_chains or identity in chains or semantics != expected_chains[identity]:
                raise CaptureError("nft chain is unexpected, duplicated, or semantically wrong")
            chains.add(identity)
            structure.append({"chain": [*identity, *semantics]})
            continue
        if kind != "rule":
            raise CaptureError("nft ruleset contains an unexpected entity")
        if set(value).difference({"family", "table", "chain", "handle", "expr", "comment"}):
            raise CaptureError("nft rule contains unexpected attributes")
        comment = value.get("comment")
        if not isinstance(comment, str) or comment not in by_comment or comment in counters:
            raise CaptureError("nft rule is uncommented, unknown, or duplicated")
        expected_rule = by_comment[comment]
        identity = (value.get("family"), value.get("table"), value.get("chain"))
        if identity != (expected_rule["family"], expected_rule["table"], expected_rule["chain"]):
            raise CaptureError("nft rule is placed in the wrong chain")
        expressions = value.get("expr")
        if not isinstance(expressions, list):
            raise CaptureError("nft rule expressions have an invalid shape")
        normalized = _normalize_expression(expressions)
        if normalized != _normalize_expression(expected_rule["expr"], expected=True):
            raise CaptureError("nft match, counter, verdict, or NAT semantics differ")
        counter_values = [
            expression["counter"]
            for expression in expressions
            if isinstance(expression, dict) and set(expression) == {"counter"}
        ]
        if len(counter_values) != 1:
            raise CaptureError("nft rule must contain exactly one counter")
        counters[comment] = {
            "comment": comment,
            "packets": counter_values[0]["packets"],
            "bytes": counter_values[0]["bytes"],
        }
        observed_order[identity].append(comment)
        structure.append({"rule": {"identity": list(identity), "comment": comment, "expr": normalized}})
    if tables != expected_tables or chains != set(expected_chains) or set(counters) != set(by_comment):
        raise CaptureError("nft tables, chains, or rules are missing")
    if observed_order != expected_order:
        raise CaptureError("nft rule order differs from the frozen policy")
    return {
        "sha256": _canonical_hash(document),
        "structureSha256": _canonical_hash(structure),
        "tableCount": len(tables),
        "chainCount": len(chains),
        "ruleCount": len(counters),
        "allowlistedCounters": [counters[name] for name in sorted(counters)],
    }


def _read_ready_file(path: str) -> Tuple[Mapping[str, object], Mapping[str, object]]:
    raw = _read_private_regular(path, MAX_READY_BYTES, "ready file")
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=_object_without_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, CaptureError) as exc:
        raise CaptureError("ready file is not strict UTF-8 JSON") from exc
    required = {"bind", "port", "allowedClient", "policyProfile", "policySha256"}
    if not isinstance(document, dict) or set(document) != required:
        raise CaptureError("ready file fields do not match the strict schema")
    if (
        document["bind"] != LAB_ADDRESS
        or type(document["port"]) is not int
        or document["port"] != PROXY_PORT
        or document["allowedClient"] != SUT_ADDRESS
        or document["policyProfile"] not in {"vm006a", "vm006b"}
        or not isinstance(document["policySha256"], str)
        or not HEX_SHA256.fullmatch(document["policySha256"])
    ):
        raise CaptureError("ready file is not bound to the frozen proxy")
    return document, {
        "sha256": _sha256(raw),
        "size": len(raw),
        "mode": "0600",
        "profile": document["policyProfile"],
        "policySha256": document["policySha256"],
    }


def _read_proc_file(pid: int, name: str, maximum: int) -> bytes:
    try:
        fd = os.open(f"/proc/{pid}/{name}", os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as exc:
        raise CaptureError("fault-proxy process identity cannot be read") from exc
    try:
        return _read_fd(fd, maximum)
    finally:
        os.close(fd)


def _resolve_process_argument(argument: str, cwd: str) -> str:
    if not argument or "\0" in argument:
        raise CaptureError("fault-proxy argv path is invalid")
    return os.path.realpath(argument if os.path.isabs(argument) else os.path.join(cwd, argument))


def _validate_active_private_file(path: str, label: str) -> None:
    try:
        value = os.lstat(path)
    except OSError as exc:
        raise CaptureError(f"{label} cannot be inspected") from exc
    if stat.S_ISLNK(value.st_mode):
        raise CaptureError(f"{label} must not be a symbolic link")
    _validate_owned_stat(value, exact_mode=0o600, expected_uid=0)


def _inspect_fault_proxy_process(
    pid: int,
    fixture_root: str,
    ready_path: str,
    ready: Mapping[str, object],
    proxy_module: Any,
    fixture_files: Mapping[str, bytes],
) -> Mapping[str, object]:
    try:
        process_stat = os.stat(f"/proc/{pid}")
        executable = os.path.realpath(os.readlink(f"/proc/{pid}/exe"))
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError as exc:
        raise CaptureError("fault-proxy process disappeared") from exc
    if not stat.S_ISDIR(process_stat.st_mode) or process_stat.st_uid != 0 or not PYTHON_EXE.fullmatch(executable):
        raise CaptureError("fault-proxy is not a root-owned system python3 process")
    try:
        status = _read_proc_file(pid, "status", 65536).decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CaptureError("fault-proxy status is not UTF-8") from exc
    uid_lines = [line for line in status.splitlines() if line.startswith("Uid:")]
    if len(uid_lines) != 1 or uid_lines[0].split()[1:] != ["0", "0", "0", "0"]:
        raise CaptureError("fault-proxy UIDs are not all root")
    cmdline = _read_proc_file(pid, "cmdline", 65536)
    if not cmdline.endswith(b"\0"):
        raise CaptureError("fault-proxy argv is incomplete")
    try:
        argv = [item.decode("utf-8", errors="strict") for item in cmdline[:-1].split(b"\0")]
    except UnicodeDecodeError as exc:
        raise CaptureError("fault-proxy argv is not UTF-8") from exc
    if (
        len(argv) != 10
        or argv[0] != "/usr/bin/python3"
        or argv[1:3] != ["-I", "-B"]
        or argv[4::2] != ["--policy", "--log", "--ready-file"]
    ):
        raise CaptureError("fault-proxy argv does not match the frozen invocation")
    script = _resolve_process_argument(argv[3], cwd)
    if script != os.path.join(os.path.realpath(fixture_root), "fault_proxy.py"):
        raise CaptureError("fault-proxy script is outside the trusted fixture")
    policy_path = _resolve_process_argument(argv[5], cwd)
    log_path = _resolve_process_argument(argv[7], cwd)
    process_ready = _resolve_process_argument(argv[9], cwd)
    if process_ready != os.path.realpath(ready_path):
        raise CaptureError("fault-proxy argv ready path differs")
    _validate_active_private_file(log_path, "fault-proxy log")
    try:
        proxy_policy = proxy_module.load_policy(Path(policy_path))
    except ValueError as exc:
        raise CaptureError("fault-proxy policy failed validation") from exc
    if proxy_policy.profile != ready["policyProfile"] or proxy_policy.sha256 != ready["policySha256"]:
        raise CaptureError("fault-proxy policy differs from ready identity")
    return {
        "pid": pid,
        "uid": 0,
        "name": "python3",
        "executableSha256": _sha256(executable.encode()),
        "argvSha256": _canonical_hash(argv),
        "scriptSha256": _sha256(fixture_files["fault_proxy.py"]),
        "readyPathSha256": _sha256(process_ready.encode()),
        "policyProfile": proxy_policy.profile,
        "policySha256": proxy_policy.sha256,
    }


def _listener_identity(
    data: bytes,
    profile: str,
    fixture_root: str,
    ready_path: Optional[str],
    ready: Optional[Mapping[str, object]],
    process_inspector: Optional[ProcessInspector],
    proxy_module: Any,
    fixture_files: Mapping[str, bytes],
) -> Mapping[str, object]:
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CaptureError("ss returned non-UTF-8 output") from exc
    inventory = []
    matches = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[0] not in ("tcp", "udp"):
            raise CaptureError("ss returned an invalid socket row")
        protocol, state, local = fields[0], fields[1], fields[4]
        endpoint = re.fullmatch(r"(.+):([0-9]+)", local)
        if endpoint is None:
            raise CaptureError("ss returned an invalid local endpoint")
        record = {"protocol": protocol, "state": state, "local": local}
        inventory.append(record)
        if int(endpoint.group(2)) == PROXY_PORT:
            matches.append((record, " ".join(fields[6:])))
    inventory.sort(key=_canonical_bytes)
    result: Dict[str, object] = {
        "socketInventorySha256": _canonical_hash(inventory),
        "socketCount": len(inventory),
        "present": bool(matches),
        "count": len(matches),
    }
    if profile != "vm006":
        if ready_path is not None or ready is not None or matches:
            raise CaptureError("VM-004 forbids ready-file and every port-7897 bind")
        return result
    if ready_path is None or ready is None or len(matches) != 1:
        raise CaptureError("VM-006 requires one listener and a validated ready file")
    record, process_text = matches[0]
    if record != {"protocol": "tcp", "state": "LISTEN", "local": LISTENER_ENDPOINT}:
        raise CaptureError("VM-006 listener protocol, state, or bind is wrong")
    process_match = PROCESS_USERS.fullmatch(process_text)
    if process_match is None:
        raise CaptureError("VM-006 listener is not uniquely owned by python3")
    pid = int(process_match.group(1))
    if process_inspector is None:
        process = _inspect_fault_proxy_process(
            pid, fixture_root, ready_path, ready, proxy_module, fixture_files
        )
    else:
        process = process_inspector(pid, fixture_root, ready_path, ready)
    required = {
        "pid", "uid", "name", "executableSha256", "argvSha256", "scriptSha256",
        "readyPathSha256", "policyProfile", "policySha256",
    }
    if not isinstance(process, Mapping) or set(process) != required:
        raise CaptureError("fault-proxy process identity has the wrong shape")
    hashes = ("executableSha256", "argvSha256", "scriptSha256", "readyPathSha256", "policySha256")
    if (
        process["pid"] != pid
        or process["uid"] != 0
        or process["name"] != "python3"
        or process["policyProfile"] != ready["policyProfile"]
        or process["policySha256"] != ready["policySha256"]
        or process["readyPathSha256"] != _sha256(os.path.realpath(ready_path).encode())
        or any(not isinstance(process[field], str) or not HEX_SHA256.fullmatch(process[field]) for field in hashes)
    ):
        raise CaptureError("fault-proxy process is not bound to ready identity")
    result["process"] = dict(process)
    return result


def _read_os_release() -> Mapping[str, str]:
    _require_posix_security()
    try:
        before = os.lstat(OS_RELEASE)
    except OSError as exc:
        raise CaptureError("os-release cannot be inspected") from exc
    if stat.S_ISLNK(before.st_mode):
        raise CaptureError("os-release must not be a symlink")
    _validate_owned_stat(before, expected_uid=0)
    try:
        fd = os.open(OS_RELEASE, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as exc:
        raise CaptureError("os-release cannot be opened safely") from exc
    try:
        opened = os.fstat(fd)
        _validate_owned_stat(opened, expected_uid=0)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise CaptureError("os-release identity changed")
        raw = _read_fd(fd, 65536)
    finally:
        os.close(fd)
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CaptureError("os-release is not strict UTF-8") from exc
    values: Dict[str, str] = {}
    for line in text.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        if key not in ("ID", "VERSION_ID", "VERSION_CODENAME"):
            continue
        try:
            parsed = shlex.split(raw_value, posix=True)
        except ValueError as exc:
            raise CaptureError("os-release has invalid quoting") from exc
        if len(parsed) != 1 or not SAFE_OS_VALUE.fullmatch(parsed[0]):
            raise CaptureError("os-release identity is unsafe")
        values[key] = parsed[0]
    if "ID" not in values or "VERSION_ID" not in values:
        raise CaptureError("os-release lacks identity fields")
    return {
        "id": values["ID"],
        "versionId": values["VERSION_ID"],
        "versionCodename": values.get("VERSION_CODENAME", ""),
    }


def _kernel_release(runner: Runner) -> str:
    try:
        value = _invoke(runner, (UNAME, "-r")).decode("ascii", errors="strict").strip()
    except UnicodeDecodeError as exc:
        raise CaptureError("uname returned non-ASCII output") from exc
    if not SAFE_KERNEL_VALUE.fullmatch(value):
        raise CaptureError("uname returned an unsafe identity")
    return value


def _captured_at(value: Optional[dt.datetime]) -> str:
    current = value or dt.datetime.now(dt.timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise CaptureError("capture time must be timezone-aware")
    return current.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def collect_gateway_state(
    *,
    fixture_root: str,
    policy: str,
    profile: str,
    wan_interface: str,
    lan_interface: str,
    ready_file: Optional[str] = None,
    runner: Optional[Runner] = None,
    process_inspector: Optional[ProcessInspector] = None,
    captured_at: Optional[dt.datetime] = None,
    fixture_context: Optional[FixtureContext] = None,
) -> Mapping[str, object]:
    """Collect state. Runner/process injection is available only through this unit API."""

    _require_posix_security()
    if fixture_context is None:
        raise CaptureError("capture requires an explicit bound fixture context")
    if runner is None:
        _require_production_root()
        if not fixture_context.production_trusted or fixture_context.root_fd is None:
            raise CaptureError("production capture requires a bound trusted fixture context")
    elif fixture_context.production_trusted:
        raise CaptureError("unit command injection must not reuse a production fixture context")
    if process_inspector is None and runner is not None and profile == "vm006":
        raise CaptureError("VM-006 unit runner requires a unit process inspector")
    if process_inspector is not None and runner is None:
        raise CaptureError("process-inspector injection requires an injected runner")
    if os.path.abspath(fixture_root) != fixture_context.root_path:
        raise CaptureError("fixture argument differs from the bound fixture context")
    try:
        if not INTERFACE_PATTERN.fullmatch(wan_interface) or not INTERFACE_PATTERN.fullmatch(lan_interface):
            raise CaptureError("interface name is invalid")
        if wan_interface == lan_interface or "lo" in (wan_interface, lan_interface):
            raise CaptureError("WAN, LAN, and loopback must differ")
        if profile not in PROFILES:
            raise CaptureError("unsupported Gateway profile")
        if (profile == "vm006") != bool(ready_file):
            raise CaptureError("ready-file is required only for VM-006")
        parsed_policy, policy_identity = _load_network_policy(
            policy, profile, fixture_context.gateway_policy
        )
        command_runner = runner or _production_runner
        os_identity = dict(_read_os_release())
        os_identity["kernel"] = _kernel_release(command_runner)
        network = _network_topology(command_runner, wan_interface, lan_interface)
        forwarding = {
            "ipv4": _sysctl_bit(command_runner, "net.ipv4.ip_forward"),
            "ipv6All": _sysctl_bit(command_runner, "net.ipv6.conf.all.forwarding"),
            "ipv6Default": _sysctl_bit(command_runner, "net.ipv6.conf.default.forwarding"),
        }
        if forwarding != {"ipv4": 1, "ipv6All": 0, "ipv6Default": 0}:
            raise CaptureError("forwarding sysctls differ from the isolation policy")
        nft = _nft_identity(
            _invoke(command_runner, (NFT, "-j", "list", "ruleset")),
            _expected_nft_rules(parsed_policy, wan_interface, lan_interface),
        )
        ready_document = ready_identity = None
        if ready_file is not None:
            ready_document, ready_identity = _read_ready_file(ready_file)
        listener = _listener_identity(
            _invoke(command_runner, (SS, "-H", "-lntup")),
            profile,
            fixture_context.root_path,
            ready_file,
            ready_document,
            process_inspector,
            fixture_context.fault_proxy,
            fixture_context.files,
        )
        document: Dict[str, object] = {
            "schemaVersion": 1,
            "capturedAtUtc": _captured_at(captured_at),
            "os": os_identity,
            "fixture": fixture_context.identity,
            "policy": policy_identity,
            "forwarding": forwarding,
            "network": {key: value for key, value in network.items() if key != "interfaces"},
            "interfaces": network["interfaces"],
            "nftables": nft,
            "legacyFirewall": {
                "iptablesSha256": _sha256(_invoke(command_runner, (IPTABLES_SAVE,))),
                "ip6tablesSha256": _sha256(_invoke(command_runner, (IP6TABLES_SAVE,))),
            },
            "faultProxyListener": listener,
        }
        if ready_identity is not None:
            document["faultProxyReady"] = ready_identity
        return document
    finally:
        pass


def _open_trusted_output_parent(output: str) -> Tuple[int, str, Mapping[str, object]]:
    _require_posix_security()
    absolute = _normalized_absolute_path(output, "evidence output")
    parent, name = os.path.dirname(absolute), os.path.basename(absolute)
    if not name or name in (".", "..") or os.sep in name:
        raise CaptureError("evidence output basename is invalid")
    current_fd = _open_trusted_directory_chain(parent, expected_uid=0)
    try:
        metadata = os.fstat(current_fd)
        _validate_owned_stat(metadata, directory=True, expected_uid=0)
        identity = {
            "device": metadata.st_dev,
            "inode": metadata.st_ino,
            "uid": metadata.st_uid,
            "mode": stat.S_IMODE(metadata.st_mode),
        }
        return current_fd, name, {"sha256": _canonical_hash(identity)}
    except Exception:
        os.close(current_fd)
        raise


def _write_gateway_state_to_parent(
    parent_fd: int,
    name: str,
    document: Mapping[str, object],
    *,
    expected_uid: int,
) -> None:
    metadata = os.fstat(parent_fd)
    _validate_owned_stat(metadata, directory=True, expected_uid=expected_uid)
    identity = {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "uid": metadata.st_uid,
        "mode": stat.S_IMODE(metadata.st_mode),
    }
    parent_identity = {"sha256": _canonical_hash(identity)}
    enriched = dict(document)
    enriched["evidenceParent"] = parent_identity
    payload = _canonical_bytes(enriched) + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
    fd = -1
    opened = None
    success = False
    try:
        try:
            fd = os.open(name, flags, 0o600, dir_fd=parent_fd)
        except OSError as exc:
            raise CaptureError("evidence output cannot be created safely") from exc
        os.fchmod(fd, 0o600)
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != expected_uid or stat.S_IMODE(opened.st_mode) != 0o600:
            raise CaptureError("evidence output identity or mode is unsafe")
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise CaptureError("evidence write made no progress")
            offset += written
        os.fsync(fd)
        os.fsync(parent_fd)
        success = True
    except OSError as exc:
        raise CaptureError("evidence output could not be written") from exc
    finally:
        if fd >= 0:
            os.close(fd)
        if not success and opened is not None:
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino):
                    os.unlink(name, dir_fd=parent_fd)
            except OSError:
                pass


def write_gateway_state(output: str, document: Mapping[str, object]) -> None:
    """Create one root-owned 0600 file through a fully trusted parent chain; never overwrite."""

    parent_fd, name, _ = _open_trusted_output_parent(output)
    try:
        _write_gateway_state_to_parent(parent_fd, name, document, expected_uid=0)
    finally:
        os.close(parent_fd)


def capture_to_path(
    *,
    output: str,
    fixture_root: str,
    policy: str,
    profile: str,
    wan_interface: str,
    lan_interface: str,
    ready_file: Optional[str] = None,
    runner: Optional[Runner] = None,
    process_inspector: Optional[ProcessInspector] = None,
    captured_at: Optional[dt.datetime] = None,
    fixture_context: Optional[FixtureContext] = None,
) -> None:
    owns_context = False
    if fixture_context is None and runner is None:
        fixture_context = _load_production_fixture_context(fixture_root)
        owns_context = True
    try:
        document = collect_gateway_state(
            fixture_root=fixture_root,
            policy=policy,
            profile=profile,
            wan_interface=wan_interface,
            lan_interface=lan_interface,
            ready_file=ready_file,
            runner=runner,
            process_inspector=process_inspector,
            captured_at=captured_at,
            fixture_context=fixture_context,
        )
        write_gateway_state(output, document)
    finally:
        if owns_context and fixture_context is not None:
            fixture_context.close()


def _is_isolated_no_bytecode_runtime() -> bool:
    return sys.flags.isolated == 1 and bool(sys.dont_write_bytecode)


def main(argv: Optional[Sequence[str]] = None) -> int:
    if not _is_isolated_no_bytecode_runtime():
        print("Gateway state capture failed.", file=sys.stderr)
        return 64
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--fixture-root", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("--wan-interface", required=True)
    parser.add_argument("--lan-interface", required=True)
    parser.add_argument("--ready-file")
    args = parser.parse_args(argv)
    fixture_context: Optional[FixtureContext] = None
    try:
        _require_production_root()
        fixture_context = _load_production_fixture_context(args.fixture_root)
        script_root = os.path.abspath(os.path.dirname(__file__))
        if script_root != fixture_context.root_path:
            raise CaptureError("running capture script differs from the bound fixture root")
        capture_to_path(
            output=args.output,
            fixture_root=args.fixture_root,
            policy=args.policy,
            profile=args.profile,
            wan_interface=args.wan_interface,
            lan_interface=args.lan_interface,
            ready_file=args.ready_file,
            fixture_context=fixture_context,
        )
    except CaptureError:
        print("Gateway state capture failed.", file=sys.stderr)
        return 64
    finally:
        if fixture_context is not None:
            fixture_context.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
