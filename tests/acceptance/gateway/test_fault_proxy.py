import io
import json
import unittest

from fault_proxy import EventLogger, Policy, parse_connect_line
import ipaddress


class FaultProxyTests(unittest.TestCase):
    def test_parses_https_connect_only(self):
        self.assertEqual(("example.com", 443), parse_connect_line(b"CONNECT Example.COM:443 HTTP/1.1\r\n"))
        for line in (b"GET https://example.com/ HTTP/1.1", b"CONNECT user@example.com:443 HTTP/1.1", b"CONNECT example.com:80 HTTP/1.1"):
            with self.assertRaises(ValueError):
                parse_connect_line(line)

    def test_policy_relays_only_probe_host(self):
        policy = Policy(ipaddress.ip_address("192.168.77.10"), "probe-then-drop", "www.microsoft.com", 1, 1)
        self.assertEqual("relay", policy.action_for("www.microsoft.com"))
        self.assertEqual("drop", policy.action_for("download.example"))

    def test_log_schema_cannot_contain_headers_or_body(self):
        output = io.StringIO()
        EventLogger(output).write("192.168.77.10", "example.com", 443, "transfer-dropped", 42)
        record = json.loads(output.getvalue())
        self.assertEqual({"bytes", "client", "event", "targetHost", "targetPort", "timestamp"}, set(record))
        self.assertNotIn("authorization", output.getvalue().lower())
        self.assertNotIn("secret-value", output.getvalue())


if __name__ == "__main__":
    unittest.main()
