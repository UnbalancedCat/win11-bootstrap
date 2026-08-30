import datetime as dt
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import capture_gateway_state as capture
import fault_proxy
import gateway_policy


POSIX_SECURITY = os.name == "posix" and all(
    hasattr(os, name) for name in ("geteuid", "O_NOFOLLOW", "O_DIRECTORY", "O_CLOEXEC")
)
CHAINS = {
    ("inet", "w11b_lab", "input"): ("filter", "input", 0, "accept"),
    ("inet", "w11b_lab", "forward"): ("filter", "forward", 0, "drop"),
    ("ip", "w11b_lab_nat", "postrouting"): ("nat", "postrouting", 100, "accept"),
}


def nft_document(expected_rules, mutate=None):
    grouped = {identity: [] for identity in CHAINS}
    for expected in expected_rules:
        identity = (expected["family"], expected["table"], expected["chain"])
        expressions = []
        for expression in expected["expr"]:
            expressions.append(
                {"counter": {"packets": 3, "bytes": 300}}
                if set(expression) == {"counter"}
                else json.loads(json.dumps(expression))
            )
        grouped[identity].append(
            {
                "rule": {
                    "family": identity[0],
                    "table": identity[1],
                    "chain": identity[2],
                    "handle": len(grouped[identity]) + 10,
                    "comment": expected["comment"],
                    "expr": expressions,
                }
            }
        )
    entries = [{"metainfo": {"json_schema_version": 1}}]
    for family, table in (("inet", "w11b_lab"), ("ip", "w11b_lab_nat")):
        entries.append({"table": {"family": family, "name": table, "handle": 1}})
        for identity, semantics in CHAINS.items():
            if identity[:2] != (family, table):
                continue
            entries.append(
                {
                    "chain": {
                        "family": family,
                        "table": table,
                        "name": identity[2],
                        "handle": 2,
                        "type": semantics[0],
                        "hook": semantics[1],
                        "prio": semantics[2],
                        "policy": semantics[3],
                    }
                }
            )
            entries.extend(grouped[identity])
    document = {"nftables": entries}
    if mutate:
        mutate(document)
    return document


class FakeRunner:
    def __init__(
        self,
        expected_rules,
        *,
        nft_mutator=None,
        extra_link=False,
        lan_default=False,
        ipv6_guard=None,
        bad_rule=False,
        bad_forwarding=None,
        listener="none",
        fail_executable=None,
    ):
        self.expected_rules = expected_rules
        self.nft_mutator = nft_mutator
        self.extra_link = extra_link
        self.lan_default = lan_default
        self.ipv6_guard = ipv6_guard
        self.bad_rule = bad_rule
        self.bad_forwarding = bad_forwarding
        self.listener = listener
        self.fail_executable = fail_executable

    @staticmethod
    def encoded(value):
        return json.dumps(value, separators=(",", ":")).encode()

    def __call__(self, argv):
        if self.fail_executable == argv[0]:
            raise RuntimeError("raw private failure")
        if argv[0] == capture.UNAME:
            return b"6.8.0-test\n"
        if argv[0] == capture.IPTABLES_SAVE or argv[0] == capture.IP6TABLES_SAVE:
            return b""
        if argv[0] == capture.SYSCTL:
            expected = {
                "net.ipv4.ip_forward": "1",
                "net.ipv6.conf.all.forwarding": "0",
                "net.ipv6.conf.default.forwarding": "0",
            }
            value = expected[argv[-1]]
            if self.bad_forwarding == argv[-1]:
                value = "0" if value == "1" else "1"
            return (value + "\n").encode()
        if argv[0] == capture.NFT:
            return self.encoded(nft_document(self.expected_rules, self.nft_mutator))
        if argv[0] == capture.SS:
            rows = ['tcp LISTEN 0 16 8.8.4.4:22 0.0.0.0:* users:(("sshd",pid=12,fd=3))']
            if self.listener == "valid":
                rows.append('tcp LISTEN 0 16 192.168.77.1:7897 0.0.0.0:* users:(("python3",pid=4242,fd=4))')
            elif self.listener == "udp":
                rows.append('udp UNCONN 0 0 192.168.77.1:7897 0.0.0.0:* users:(("python3",pid=4242,fd=4))')
            elif self.listener == "wildcard":
                rows.append('tcp LISTEN 0 16 0.0.0.0:7897 0.0.0.0:* users:(("python3",pid=4242,fd=4))')
            return ("\n".join(rows) + "\n").encode()
        if argv[0] != capture.IP:
            raise AssertionError(argv)
        if argv == (capture.IP, "-j", "-details", "link", "show"):
            links = [
                {"ifname": "lo", "flags": ["LOOPBACK", "UP"], "mtu": 65536, "address": "00:00:00:00:00:00"},
                {"ifname": "wan0", "flags": ["BROADCAST", "UP"], "mtu": 1500, "address": "aa:bb:cc:dd:ee:01"},
                {"ifname": "lan0", "flags": ["BROADCAST", "UP"], "mtu": 1500, "address": "aa:bb:cc:dd:ee:02"},
            ]
            if self.extra_link:
                links.append({"ifname": "eth2", "flags": ["UP"], "mtu": 1500, "address": "aa:bb:cc:dd:ee:03"})
            return self.encoded(links)
        if argv == (capture.IP, "-j", "address", "show"):
            return self.encoded(
                [
                    {"ifname": "lo", "addr_info": [{"family": "inet", "local": "127.0.0.1", "prefixlen": 8, "scope": "host"}]},
                    {"ifname": "wan0", "addr_info": [{"family": "inet", "local": "8.8.4.4", "prefixlen": 24, "scope": "global"}]},
                    {"ifname": "lan0", "addr_info": [{"family": "inet", "local": "192.168.77.1", "prefixlen": 24, "scope": "global"}]},
                ]
            )
        if argv == (capture.IP, "-j", "-4", "route", "show", "table", "all"):
            routes = [
                {"dst": "default", "gateway": "8.8.4.1", "dev": "wan0", "protocol": "dhcp", "scope": "global", "table": "main"},
                {"dst": "8.8.4.0/24", "dev": "wan0", "protocol": "kernel", "scope": "link", "table": "main"},
                {"dst": "192.168.77.0/24", "dev": "lan0", "protocol": "kernel", "scope": "link", "table": "main"},
                {"dst": "127.0.0.0/8", "dev": "lo", "protocol": "kernel", "scope": "host", "table": "local"},
            ]
            if self.lan_default:
                routes.append({"dst": "default", "dev": "lan0", "protocol": "static", "scope": "global", "table": "main"})
            return self.encoded(routes)
        if argv == (capture.IP, "-j", "-6", "route", "show", "table", "all"):
            routes = [
                {"dst": "fe80::/64", "dev": "wan0", "protocol": "kernel", "scope": "link", "table": "main"},
                {"dst": "fe80::/64", "dev": "lan0", "protocol": "kernel", "scope": "link", "table": "main"},
                {"dst": "::1/128", "dev": "lo", "protocol": "kernel", "scope": "host", "table": "local"},
            ]
            if self.ipv6_guard is not None:
                routes.append(json.loads(json.dumps(self.ipv6_guard)))
            return self.encoded(routes)
        if argv == (capture.IP, "-j", "-4", "rule", "show"):
            rules = [
                {"priority": 0, "src": "all", "table": "local"},
                {"priority": 32766, "src": "all", "table": "main"},
                {"priority": 32767, "src": "all", "table": "default"},
            ]
            if self.bad_rule:
                rules.insert(1, {"priority": 100, "src": "all", "table": "main", "fwmark": "1"})
            return self.encoded(rules)
        if argv == (capture.IP, "-j", "-6", "rule", "show"):
            rules = [
                {"priority": 0, "src": "all", "table": "local"},
                {"priority": 32766, "src": "all", "table": "main"},
            ]
            if self.bad_rule:
                rules.insert(1, {"priority": 100, "src": "all", "table": "main", "fwmark": "1"})
            return self.encoded(rules)
        raise AssertionError(argv)


@unittest.skipUnless(POSIX_SECURITY, "POSIX no-follow and ownership semantics are required")
class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.fixture = self.base / "fixture"
        self.fixture.mkdir(mode=0o700)
        for name in capture.FIXTURE_FILE_ALLOWLIST:
            path = self.fixture / name
            path.write_text("trusted fixture\n", encoding="ascii")
            os.chmod(path, 0o644)
        self.fixture_files = {
            name: (self.fixture / name).read_bytes() for name in capture.FIXTURE_FILE_ALLOWLIST
        }
        self.fixture_context = capture._unit_fixture_context(
            str(self.fixture), self.fixture_files, gateway_policy, fault_proxy
        )
        self.policy = self.base / "policy.json"
        self.time = dt.datetime(2026, 8, 30, tzinfo=dt.timezone.utc)
        self.os_patch = mock.patch.object(
            capture,
            "_read_os_release",
            return_value={"id": "ubuntu", "versionId": "26.04", "versionCodename": "test"},
        )
        self.os_patch.start()
        self.addCleanup(self.os_patch.stop)
        self.write_policy("vm004-runtime")

    def write_loader_fixture(self, root, sentinel, execute_marker=None):
        root.mkdir()
        marker_statement = ""
        if execute_marker is not None:
            marker_statement = (
                "from pathlib import Path\n"
                f"Path({str(execute_marker)!r}).write_text('executed', encoding='ascii')\n"
            )
        sources = {
            "capture_gateway_state.py": b"# trusted capture bytes\n",
            "configure_gateway.sh": b"#!/bin/sh\n",
            "gateway_policy.py": (
                marker_statement
                + "PROFILES={'vm004-bootstrap','vm004-subscription','vm004-runtime','vm006'}\n"
                + "SUT_ADDRESS='192.168.77.10'\n"
                + "PROXY_PORT=7897\n"
                + f"SENTINEL={sentinel!r}\n"
            ).encode("utf-8"),
            "fault_proxy.py": (
                "import ipaddress\n"
                "BIND_ADDRESS='192.168.77.1'\n"
                "BIND_PORT=7897\n"
                "ALLOWED_CLIENT=ipaddress.ip_address('192.168.77.10')\n"
                f"SENTINEL={sentinel!r}\n"
            ).encode("utf-8"),
        }
        for name, data in sources.items():
            path = root / name
            path.write_bytes(data)
            os.chmod(path, 0o644)
        return sources

    def write_policy(self, profile):
        document = {
            "schemaVersion": 1,
            "profile": profile,
            "blocked": [{"address": "8.8.8.8", "protocol": "tcp", "port": 443}],
            "allowed": [] if profile == "vm006" else [{"address": "1.1.1.1", "protocol": "tcp", "port": 8443}],
        }
        self.policy.write_text(json.dumps(document, separators=(",", ":")), encoding="utf-8")
        os.chmod(self.policy, 0o600)

    def runner(self, profile, **kwargs):
        policy = gateway_policy.load_policy(str(self.policy), profile)
        return FakeRunner(capture._expected_nft_rules(policy, "wan0", "lan0"), **kwargs)

    def ready(self):
        path = self.base / "ready.json"
        path.write_text(
            json.dumps(
                {
                    "bind": "192.168.77.1",
                    "port": 7897,
                    "allowedClient": "192.168.77.10",
                    "policyProfile": "vm006a",
                    "policySha256": "a" * 64,
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        os.chmod(path, 0o600)
        return path

    @staticmethod
    def inspector(pid, _fixture, ready_path, ready):
        return {
            "pid": pid,
            "uid": 0,
            "name": "python3",
            "executableSha256": "b" * 64,
            "argvSha256": "c" * 64,
            "scriptSha256": "d" * 64,
            "readyPathSha256": capture._sha256(os.path.realpath(ready_path).encode()),
            "policyProfile": ready["policyProfile"],
            "policySha256": ready["policySha256"],
        }

    def collect(self, profile="vm004-runtime", runner=None, ready=None, inspector=None):
        return capture.collect_gateway_state(
            fixture_root=str(self.fixture),
            policy=str(self.policy),
            profile=profile,
            wan_interface="wan0",
            lan_interface="lan0",
            ready_file=None if ready is None else str(ready),
            runner=runner or self.runner(profile),
            process_inspector=inspector,
            captured_at=self.time,
            fixture_context=self.fixture_context,
        )

    def test_valid_vm004_is_redacted_and_policy_bound(self):
        self.assertNotIn("fault_proxy", capture.__dict__)
        self.assertNotIn("gateway_policy", capture.__dict__)
        self.assertIs(fault_proxy, self.fixture_context.fault_proxy)
        self.assertIs(gateway_policy, self.fixture_context.gateway_policy)
        document = self.collect()
        encoded = json.dumps(document)
        for secret in ("8.8.4.4", "8.8.8.8", "1.1.1.1", "wan0", "lan0", str(self.policy)):
            self.assertNotIn(secret, encoded)
        self.assertEqual("vm004-runtime", document["policy"]["profile"])
        self.assertEqual({"ipv4": 1, "ipv6All": 0, "ipv6Default": 0}, document["forwarding"])

    def test_nft_missing_unknown_duplicate_wrong_chain_action_and_match_fail(self):
        def missing(doc):
            doc["nftables"] = [entry for entry in doc["nftables"] if entry.get("rule", {}).get("comment") != "w11b-forward-default-drop"]
        def unknown(doc):
            rule = json.loads(json.dumps(next(entry["rule"] for entry in doc["nftables"] if "rule" in entry)))
            rule["comment"] = "unknown"
            doc["nftables"].append({"rule": rule})
        def duplicate(doc):
            doc["nftables"].append(json.loads(json.dumps(next(entry for entry in doc["nftables"] if "rule" in entry))))
        def uncommented(doc):
            next(entry["rule"] for entry in doc["nftables"] if "rule" in entry).pop("comment")
        def reordered(doc):
            positions = [index for index, entry in enumerate(doc["nftables"]) if "rule" in entry]
            first, second = positions[:2]
            doc["nftables"][first], doc["nftables"][second] = doc["nftables"][second], doc["nftables"][first]
        def chain(doc):
            next(entry["rule"] for entry in doc["nftables"] if "rule" in entry)["chain"] = "forward"
        def action(doc):
            next(entry["rule"] for entry in doc["nftables"] if "rule" in entry)["expr"][-1] = {"accept": None}
        def match(doc):
            next(entry["rule"] for entry in doc["nftables"] if "rule" in entry)["expr"][0]["match"]["right"] = "eth9"
        for mutation in (missing, unknown, duplicate, uncommented, reordered, chain, action, match):
            with self.subTest(mutation=mutation.__name__), self.assertRaises(capture.CaptureError):
                self.collect(runner=self.runner("vm004-runtime", nft_mutator=mutation))

    def test_third_nic_lan_default_policy_rule_and_forwarding_fail(self):
        runners = [
            self.runner("vm004-runtime", extra_link=True),
            self.runner("vm004-runtime", lan_default=True),
            self.runner("vm004-runtime", bad_rule=True),
        ]
        runners.extend(
            self.runner("vm004-runtime", bad_forwarding=name)
            for name in (
                "net.ipv4.ip_forward",
                "net.ipv6.conf.all.forwarding",
                "net.ipv6.conf.default.forwarding",
            )
        )
        for runner in runners:
            with self.assertRaises(capture.CaptureError):
                self.collect(runner=runner)

    def test_policy_rule_defaults_are_family_specific(self):
        ipv4 = FakeRunner.encoded(
            [
                {"priority": 0, "src": "all", "table": "local"},
                {"priority": 32766, "src": "all", "table": "main"},
                {"priority": 32767, "src": "all", "table": "default"},
            ]
        )
        ipv6 = FakeRunner.encoded(
            [
                {"priority": 0, "src": "all", "table": "local"},
                {"priority": 32766, "src": "all", "table": "main"},
            ]
        )
        self.assertEqual(3, capture._strict_policy_rules(ipv4, "inet")["count"])
        self.assertEqual(2, capture._strict_policy_rules(ipv6, "inet6")["count"])
        with self.assertRaises(capture.CaptureError):
            capture._strict_policy_rules(ipv6, "inet")
        with self.assertRaises(capture.CaptureError):
            capture._strict_policy_rules(ipv4, "inet6")

    def test_ipv6_kernel_guard_is_separate_from_usable_defaults(self):
        base = {
            "type": "unreachable",
            "dst": "default",
            "table": "unspec",
            "protocol": "kernel",
            "metric": 4294967295,
        }
        for device in (None, "lo"):
            guard = dict(base)
            if device is not None:
                guard["dev"] = device
            with self.subTest(device=device):
                document = self.collect(runner=self.runner("vm004-runtime", ipv6_guard=guard))
                identity = document["network"]["ipv6KernelGuards"]
                self.assertEqual(1, identity["count"])
                self.assertRegex(identity["sha256"], r"^[0-9a-f]{64}$")
                self.assertEqual(0, document["interfaces"]["wan"]["ipv6Routes"]["defaultCount"])
                self.assertEqual(0, document["interfaces"]["lan"]["ipv6Routes"]["defaultCount"])

    def test_ipv6_kernel_guard_rejects_near_matches(self):
        base = {
            "type": "unreachable",
            "dst": "default",
            "table": "unspec",
            "protocol": "kernel",
            "metric": 4294967295,
            "dev": "lo",
        }
        variants = (
            {**base, "type": "blackhole"},
            {**base, "protocol": "static"},
            {**base, "metric": 4294967294},
            {**base, "dev": "wan0"},
            {**base, "gateway": "::1"},
            {**base, "multipath": []},
        )
        for guard in variants:
            with self.subTest(guard=guard), self.assertRaises(capture.CaptureError):
                self.collect(runner=self.runner("vm004-runtime", ipv6_guard=guard))

    def test_listener_and_ready_profile_boundaries(self):
        ready = self.ready()
        with self.assertRaises(capture.CaptureError):
            self.collect(ready=ready)
        for listener in ("valid", "udp", "wildcard"):
            with self.assertRaises(capture.CaptureError):
                self.collect(runner=self.runner("vm004-runtime", listener=listener))
        self.write_policy("vm006")
        document = self.collect(
            "vm006",
            runner=self.runner("vm006", listener="valid"),
            ready=ready,
            inspector=self.inspector,
        )
        self.assertTrue(document["faultProxyListener"]["present"])
        for listener in ("none", "udp", "wildcard"):
            with self.assertRaises(capture.CaptureError):
                self.collect(
                    "vm006",
                    runner=self.runner("vm006", listener=listener),
                    ready=ready,
                    inspector=self.inspector,
                )

    def test_output_is_create_new_trusted_parent_0600(self):
        output = self.base / "state.json"
        parent_fd = os.open(self.base, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        self.addCleanup(os.close, parent_fd)
        capture._write_gateway_state_to_parent(
            parent_fd,
            output.name,
            self.collect(),
            expected_uid=os.geteuid(),
        )
        original = output.read_bytes()
        self.assertEqual(0o600, stat.S_IMODE(output.stat().st_mode))
        self.assertEqual(64, len(json.loads(original)["evidenceParent"]["sha256"]))
        with self.assertRaises(capture.CaptureError):
            capture._write_gateway_state_to_parent(
                parent_fd,
                output.name,
                {"schemaVersion": 1},
                expected_uid=os.geteuid(),
            )
        self.assertEqual(original, output.read_bytes())

    def test_unsafe_and_symlink_parent_fail(self):
        unsafe = self.base / "unsafe"
        unsafe.mkdir()
        os.chmod(unsafe, 0o777)
        with self.assertRaises(capture.CaptureError):
            capture.write_gateway_state(str(unsafe / "state.json"), {})
        target = self.base / "target"
        target.mkdir(mode=0o700)
        link = self.base / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(capture.CaptureError):
            capture.write_gateway_state(str(link / "state.json"), {})

    def test_fixture_chain_rejects_writable_and_nonroot_ancestors(self):
        safe = mock.Mock(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
        unsafe_values = (
            mock.Mock(st_mode=stat.S_IFDIR | 0o775, st_uid=0),
            mock.Mock(st_mode=stat.S_IFDIR | 0o755, st_uid=1000),
        )
        for unsafe in unsafe_values:
            with self.subTest(uid=unsafe.st_uid, mode=stat.S_IMODE(unsafe.st_mode)), mock.patch.object(
                capture.os, "open", side_effect=[10, 11]
            ), mock.patch.object(
                capture.os, "fstat", side_effect=[safe, unsafe]
            ), mock.patch.object(capture.os, "close"):
                with self.assertRaises(capture.CaptureError):
                    capture._open_trusted_directory_chain("/unsafe/fixture", expected_uid=0)

    def test_bound_fixture_bytes_survive_path_replacement(self):
        original = self.base / "bound-fixture"
        self.write_loader_fixture(original, "trusted")
        root_fd = os.open(original, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        displaced = self.base / "displaced-fixture"
        original.rename(displaced)
        self.write_loader_fixture(original, "malicious")
        context = capture._fixture_context_from_open_fd(
            str(original),
            root_fd,
            expected_uid=os.geteuid(),
            production_trusted=False,
        )
        self.addCleanup(context.close)
        self.assertEqual("trusted", context.gateway_policy.SENTINEL)
        self.assertEqual("trusted", context.fault_proxy.SENTINEL)
        self.assertEqual(
            capture._fixture_identity_from_bytes(
                {name: (displaced / name).read_bytes() for name in capture.FIXTURE_FILE_ALLOWLIST}
            ),
            context.identity,
        )

    def test_fixture_sibling_does_not_execute_before_all_files_validate(self):
        root = self.base / "invalid-fixture"
        marker = self.base / "module-executed.txt"
        self.write_loader_fixture(root, "unsafe", execute_marker=marker)
        os.chmod(root / "capture_gateway_state.py", 0o666)
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with self.assertRaises(capture.CaptureError):
            capture._fixture_context_from_open_fd(
                str(root),
                root_fd,
                expected_uid=os.geteuid(),
                production_trusted=False,
            )
        self.assertFalse(marker.exists())

    def test_evidence_parent_rejects_writable_ancestor(self):
        safe = mock.Mock(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
        writable = mock.Mock(st_mode=stat.S_IFDIR | 0o777, st_uid=0)
        with mock.patch.object(capture.os, "open", side_effect=[20, 21]), mock.patch.object(
            capture.os, "fstat", side_effect=[safe, writable]
        ), mock.patch.object(capture.os, "close"):
            with self.assertRaises(capture.CaptureError):
                capture._open_trusted_output_parent("/unsafe/evidence/state.json")

    def test_profile_mismatch_and_nonroot_main_fail_closed(self):
        with self.assertRaises(capture.CaptureError):
            self.collect("vm004-bootstrap", runner=FakeRunner([]))
        with mock.patch.object(capture, "_is_isolated_no_bytecode_runtime", return_value=True), mock.patch.object(
            capture.os, "geteuid", return_value=1000
        ), mock.patch.object(capture, "capture_to_path") as call:
            self.assertEqual(
                64,
                capture.main(
                    [
                        "--output", str(self.base / "unused.json"),
                        "--fixture-root", str(self.fixture),
                        "--policy", str(self.policy),
                        "--profile", "vm004-runtime",
                        "--wan-interface", "wan0",
                        "--lan-interface", "lan0",
                    ]
                ),
            )
        call.assert_not_called()

    def test_main_requires_isolated_no_bytecode_runtime(self):
        with mock.patch.object(capture, "_is_isolated_no_bytecode_runtime", return_value=False), mock.patch.object(
            capture, "capture_to_path"
        ) as call:
            self.assertEqual(64, capture.main([]))
        call.assert_not_called()

    def test_vm006_process_requires_isolated_no_bytecode_argv(self):
        ready_path = self.ready()
        ready = {
            "policyProfile": "vm006a",
            "policySha256": "a" * 64,
        }
        proxy_policy = self.base / "proxy-policy.json"
        log_path = self.base / "gateway-events.jsonl"
        argv = [
            "/usr/bin/python3",
            "-I",
            "-B",
            str(self.fixture / "fault_proxy.py"),
            "--policy",
            str(proxy_policy),
            "--log",
            str(log_path),
            "--ready-file",
            str(ready_path),
        ]
        real_stat = os.stat
        real_readlink = os.readlink

        def fake_stat(path, *args, **kwargs):
            if os.fspath(path) == "/proc/4242":
                return mock.Mock(st_mode=stat.S_IFDIR | 0o500, st_uid=0)
            return real_stat(path, *args, **kwargs)

        def fake_readlink(path, *args, **kwargs):
            value = os.fspath(path)
            if value == "/proc/4242/exe":
                return "/usr/bin/python3.12"
            if value == "/proc/4242/cwd":
                return str(self.fixture)
            return real_readlink(path, *args, **kwargs)

        def inspect(process_argv):
            cmdline = b"\0".join(item.encode() for item in process_argv) + b"\0"

            def read_proc(_pid, name, _maximum):
                return b"Uid:\t0\t0\t0\t0\n" if name == "status" else cmdline

            with mock.patch.object(capture.os, "stat", side_effect=fake_stat), mock.patch.object(
                capture.os, "readlink", side_effect=fake_readlink
            ), mock.patch.object(capture, "_read_proc_file", side_effect=read_proc), mock.patch.object(
                capture, "_validate_active_private_file"
            ), mock.patch.object(
                fault_proxy,
                "load_policy",
                return_value=mock.Mock(profile="vm006a", sha256="a" * 64),
            ):
                return capture._inspect_fault_proxy_process(
                    4242,
                    str(self.fixture),
                    str(ready_path),
                    ready,
                    fault_proxy,
                    self.fixture_context.files,
                )

        identity = inspect(argv)
        self.assertEqual("vm006a", identity["policyProfile"])
        self.assertEqual(
            capture._sha256(self.fixture_context.files["fault_proxy.py"]),
            identity["scriptSha256"],
        )
        for invalid in (argv[:1] + argv[2:], argv[:1] + ["-B", "-I"] + argv[3:]):
            with self.subTest(argv=invalid), self.assertRaises(capture.CaptureError):
                inspect(invalid)


if __name__ == "__main__":
    unittest.main()
