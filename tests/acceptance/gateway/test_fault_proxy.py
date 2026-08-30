import io
import json
import os
import socket
import stat
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from fault_proxy import (
    ALLOWED_CLIENT,
    CLIENT_HEADER_TIMEOUT_SECONDS,
    EventLogger,
    Policy,
    ProxyRule,
    _open_new_private_text,
    connect_pinned,
    dispatch_connection,
    handle,
    load_policy,
    parse_connect_line,
    relay,
)


def write_private_policy(directory: Path, value: dict, name: str = "policy.json") -> Path:
    path = directory / name
    path.write_text(json.dumps(value), encoding="utf-8")
    os.chmod(path, 0o600)
    return path


def vm006a_policy() -> dict:
    return {
        "schemaVersion": 1,
        "profile": "vm006a",
        "dropAfterBytes": 65536,
        "connectTimeoutSeconds": 10,
        "rules": [
            {"host": "www.microsoft.com", "role": "probe", "action": "reject", "addresses": []}
        ],
    }


def vm006b_policy() -> dict:
    return {
        "schemaVersion": 1,
        "profile": "vm006b",
        "dropAfterBytes": 65536,
        "connectTimeoutSeconds": 10,
        "rules": [
            {"host": "www.microsoft.com", "role": "probe", "action": "relay", "addresses": ["8.8.8.8"]},
            {"host": "cdn.example.com", "role": "metadata", "action": "relay", "addresses": ["1.1.1.1"]},
            {"host": "payload.example.com", "role": "payload", "action": "drop", "addresses": ["9.9.9.9"]},
        ],
    }


class FakeConnection:
    def __init__(self, request: bytes):
        self.request = request
        self.sent = bytearray()
        self.closed = False
        self.timeouts = []

    def recv(self, _size: int) -> bytes:
        request, self.request = self.request, b""
        return request

    def sendall(self, value: bytes) -> None:
        self.sent.extend(value)

    def close(self) -> None:
        self.closed = True

    def settimeout(self, value) -> None:
        self.timeouts.append(value)


class ChunkSocket:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.sent = bytearray()

    def recv(self, _size: int) -> bytes:
        return self.chunks.pop(0) if self.chunks else b""

    def sendall(self, value: bytes) -> None:
        self.sent.extend(value)


class FaultProxyTests(unittest.TestCase):
    def test_parses_https_dns_connect_only(self):
        self.assertEqual(("example.com", 443), parse_connect_line(b"CONNECT Example.COM:443 HTTP/1.1\r\n"))
        for line in (
            b"GET https://example.com/ HTTP/1.1",
            b"CONNECT user@example.com:443 HTTP/1.1",
            b"CONNECT example.com:80 HTTP/1.1",
            b"CONNECT example.com:+443 HTTP/1.1",
            b"CONNECT 127.0.0.1:443 HTTP/1.1",
            b"CONNECT 999.999.999.999:443 HTTP/1.1",
        ):
            with self.assertRaises(ValueError):
                parse_connect_line(line)

    def test_loads_strict_profile_policies(self):
        with tempfile.TemporaryDirectory() as temporary:
            policy = load_policy(write_private_policy(Path(temporary), vm006b_policy()))
            self.assertEqual("vm006b", policy.profile)
            self.assertEqual("drop", policy.rule_for("payload.example.com").action)
            self.assertEqual(64, len(policy.sha256))

    def test_rejects_incomplete_or_non_private_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            value = vm006b_policy()
            value["rules"] = value["rules"][:1]
            with self.assertRaisesRegex(ValueError, "metadata"):
                load_policy(write_private_policy(Path(temporary), value))
        if hasattr(os, "getuid"):
            with tempfile.TemporaryDirectory() as temporary:
                path = write_private_policy(Path(temporary), vm006a_policy())
                os.chmod(path, 0o644)
                with self.assertRaisesRegex(ValueError, "permissions"):
                    load_policy(path)

    def test_rejects_bool_schema_ip_hosts_ipv6_and_multicast(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            boolean_schema = vm006a_policy()
            boolean_schema["schemaVersion"] = True
            with self.assertRaisesRegex(ValueError, "integer 1"):
                load_policy(write_private_policy(root, boolean_schema, "bool.json"))

            ip_host = vm006a_policy()
            ip_host["rules"][0]["host"] = "127.0.0.1"
            with self.assertRaisesRegex(ValueError, "DNS name"):
                load_policy(write_private_policy(root, ip_host, "ip-host.json"))

            for index, address in enumerate(("224.0.0.1", "2001:4860:4860::8888", "ff02::1")):
                policy = vm006b_policy()
                policy["rules"][0]["addresses"] = [address]
                with self.subTest(address=address), self.assertRaisesRegex(ValueError, "global-unicast IPv4"):
                    load_policy(write_private_policy(root, policy, f"address-{index}.json"))

    def test_policy_reader_uses_descriptor_instead_of_path_read(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = write_private_policy(Path(temporary), vm006a_policy())
            with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("path read attempted")):
                self.assertEqual("vm006a", load_policy(path).profile)

    def test_reject_profile_never_opens_upstream_socket(self):
        rule = ProxyRule("www.microsoft.com", "probe", "reject", ())
        policy = Policy("vm006a", {rule.host: rule}, 65536, 10.0, "a" * 64)
        output = io.StringIO()
        connection = FakeConnection(b"CONNECT www.microsoft.com:443 HTTP/1.1\r\n\r\n")
        with mock.patch("fault_proxy.socket.socket", side_effect=AssertionError("upstream attempted")):
            handle(connection, (str(ALLOWED_CLIENT), 50000), policy, EventLogger(output))
        self.assertTrue(connection.closed)
        self.assertEqual([CLIENT_HEADER_TIMEOUT_SECONDS, None], connection.timeouts)
        self.assertIn(b"502 Lab Fault", connection.sent)
        self.assertEqual("connect-rejected", json.loads(output.getvalue())["event"])

    def test_unknown_host_is_rejected_before_connect(self):
        rule = ProxyRule("www.microsoft.com", "probe", "reject", ())
        policy = Policy("vm006a", {rule.host: rule}, 65536, 10.0, "a" * 64)
        output = io.StringIO()
        connection = FakeConnection(b"CONNECT metadata.example.com:443 HTTP/1.1\r\n\r\n")
        with mock.patch("fault_proxy.socket.socket", side_effect=AssertionError("upstream attempted")):
            handle(connection, (str(ALLOWED_CLIENT), 50000), policy, EventLogger(output))
        self.assertEqual("target-not-allowed", json.loads(output.getvalue())["event"])

    def test_connects_only_to_a_pinned_address(self):
        rule = ProxyRule("payload.example.com", "payload", "drop", ("9.9.9.9",))
        pinned_socket = mock.Mock()
        with mock.patch("fault_proxy.socket.getaddrinfo", side_effect=AssertionError("resolver used")):
            with mock.patch("fault_proxy.socket.socket", return_value=pinned_socket) as socket_factory:
                self.assertIs(pinned_socket, connect_pinned(rule, 10.0))
        socket_factory.assert_called_once_with(socket.AF_INET, socket.SOCK_STREAM)
        pinned_socket.settimeout.assert_called_once_with(10.0)
        pinned_socket.connect.assert_called_once_with(("9.9.9.9", 443))

    def test_drop_counts_only_downstream_and_stops_at_exact_limit(self):
        client = ChunkSocket([b"request" * 10000])
        upstream = ChunkSocket([b"payload" * 10000])
        with mock.patch(
            "fault_proxy.select.select",
            side_effect=[([client], [], []), ([upstream], [], [])],
        ):
            transferred = relay(client, upstream, 65536)
        self.assertEqual(65536, transferred)
        self.assertEqual(len(b"request" * 10000), len(upstream.sent))
        self.assertEqual(65536, len(client.sent))

    def test_log_schema_cannot_contain_headers_or_body(self):
        output = io.StringIO()
        EventLogger(output).write("payload", "transfer-dropped", 42)
        record = json.loads(output.getvalue())
        self.assertEqual({"bytes", "event", "role", "timestamp"}, set(record))
        self.assertEqual("payload", record["role"])
        self.assertNotIn("example.com", output.getvalue())
        self.assertNotIn("authorization", output.getvalue().lower())
        self.assertNotIn("secret-value", output.getvalue())

    def test_create_new_output_is_exactly_private_and_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.jsonl"
            with _open_new_private_text(path, "log") as stream:
                stream.write("safe\n")
            if hasattr(os, "getuid"):
                self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
            with self.assertRaises(ValueError):
                _open_new_private_text(path, "log")
            self.assertEqual("safe\n", path.read_text(encoding="utf-8"))

    def test_dispatch_is_bounded_and_releases_the_slot(self):
        class ImmediateThread:
            def __init__(self, target, args, daemon):
                self.target = target
                self.args = args
                self.daemon = daemon

            def start(self):
                self.target(*self.args)

        rule = ProxyRule("www.microsoft.com", "probe", "reject", ())
        policy = Policy("vm006a", {rule.host: rule}, 65536, 10.0, "a" * 64)
        output = io.StringIO()
        logger = EventLogger(output)
        slots = threading.BoundedSemaphore(1)
        first = FakeConnection(b"CONNECT www.microsoft.com:443 HTTP/1.1\r\n\r\n")
        with mock.patch("fault_proxy.threading.Thread", ImmediateThread):
            self.assertTrue(dispatch_connection(first, (str(ALLOWED_CLIENT), 50000), policy, logger, slots))
        self.assertTrue(slots.acquire(blocking=False))
        second = FakeConnection(b"")
        self.assertFalse(dispatch_connection(second, (str(ALLOWED_CLIENT), 50001), policy, logger, slots))
        self.assertTrue(second.closed)
        slots.release()
        events = [json.loads(line)["event"] for line in output.getvalue().splitlines()]
        self.assertEqual(["connect-rejected", "connection-limit"], events)


if __name__ == "__main__":
    unittest.main()
