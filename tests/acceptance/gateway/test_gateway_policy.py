import contextlib
import io
import json
import os
import pathlib
import re
import stat
import tempfile
import unittest
from unittest import mock

import gateway_policy


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "getuid") and hasattr(os, "O_NOFOLLOW"),
    "requires POSIX uid ownership and O_NOFOLLOW semantics",
)
class GatewayPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_policy(self, document, name="policy.json", mode=0o600):
        path = self.root / name
        path.write_text(json.dumps(document, separators=(",", ":"), sort_keys=True), encoding="utf-8")
        path.chmod(mode)
        return path

    @staticmethod
    def endpoint(address, protocol="tcp", port=443):
        return {"address": address, "protocol": protocol, "port": port}

    def valid_document(self, profile="vm004-runtime"):
        return {
            "schemaVersion": 1,
            "profile": profile,
            "blocked": [self.endpoint("8.8.8.8")],
            "allowed": [] if profile == "vm006" else [self.endpoint("1.1.1.1", port=8443)],
        }

    def test_loads_strict_private_policy_and_normalizes_order(self):
        document = self.valid_document()
        document["blocked"] = [
            self.endpoint("9.9.9.9", "udp", 53),
            self.endpoint("8.8.8.8"),
        ]
        policy = gateway_policy.load_policy(str(self.write_policy(document)), "vm004-runtime")
        self.assertEqual("vm004-runtime", policy.profile)
        self.assertEqual(("8.8.8.8", "9.9.9.9"), tuple(item.address for item in policy.blocked))
        self.assertEqual(64, len(policy.sha256))

    def test_rejects_extra_missing_and_duplicate_json_fields(self):
        extra = self.valid_document()
        extra["unexpected"] = True
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(extra, "extra.json")), "vm004-runtime")

        missing = self.valid_document()
        del missing["blocked"]
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(missing, "missing.json")), "vm004-runtime")

        duplicate = self.root / "duplicate.json"
        duplicate.write_text(
            '{"schemaVersion":1,"schemaVersion":1,"profile":"vm006",'
            '"blocked":[{"address":"8.8.8.8","protocol":"tcp","port":443}],"allowed":[]}',
            encoding="utf-8",
        )
        duplicate.chmod(0o600)
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(duplicate), "vm006")

    def test_rejects_unsafe_file_identity_and_permissions(self):
        for mode in (0o400, 0o640, 0o700):
            with self.subTest(mode=oct(mode)):
                wrong_mode = self.write_policy(self.valid_document(), f"mode-{mode:o}.json", mode)
                with self.assertRaises(gateway_policy.PolicyError):
                    gateway_policy.load_policy(str(wrong_mode), "vm004-runtime")

        private = self.write_policy(self.valid_document(), "owner.json")
        with mock.patch.object(gateway_policy.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(gateway_policy.PolicyError):
                gateway_policy.load_policy(str(private), "vm004-runtime")

        link = self.root / "policy-link.json"
        try:
            link.symlink_to(private)
        except (NotImplementedError, OSError):
            self.skipTest("symlinks are unavailable")
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(link), "vm004-runtime")

    def test_rejects_noncanonical_nonglobal_and_ipv6_addresses(self):
        for index, address in enumerate(("10.0.0.1", "224.0.0.1", "2001:4860:4860::8888", "8.8.8.8/32")):
            document = self.valid_document()
            document["blocked"] = [self.endpoint(address)]
            with self.subTest(address=address), self.assertRaises(gateway_policy.PolicyError):
                gateway_policy.load_policy(str(self.write_policy(document, f"address-{index}.json")), "vm004-runtime")

    def test_rejects_invalid_protocol_and_port_types(self):
        invalid_entries = (
            self.endpoint("8.8.8.8", "TCP", 443),
            self.endpoint("8.8.8.8", "tcp", 0),
            self.endpoint("8.8.8.8", "tcp", True),
        )
        for index, endpoint in enumerate(invalid_entries):
            document = self.valid_document()
            document["blocked"] = [endpoint]
            with self.subTest(index=index), self.assertRaises(gateway_policy.PolicyError):
                gateway_policy.load_policy(str(self.write_policy(document, f"endpoint-{index}.json")), "vm004-runtime")

    def test_rejects_duplicates_overlap_and_profile_cardinality(self):
        duplicate = self.valid_document()
        duplicate["blocked"] = [self.endpoint("8.8.8.8"), self.endpoint("8.8.8.8")]
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(duplicate, "duplicate-endpoint.json")), "vm004-runtime")

        overlap = self.valid_document()
        overlap["allowed"] = [self.endpoint("8.8.8.8")]
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(overlap, "overlap.json")), "vm004-runtime")

        empty_blocked = self.valid_document()
        empty_blocked["blocked"] = []
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(empty_blocked, "empty-blocked.json")), "vm004-runtime")

        empty_vm004_allowed = self.valid_document()
        empty_vm004_allowed["allowed"] = []
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(empty_vm004_allowed, "empty-allowed.json")), "vm004-runtime")

        vm006_allowed = self.valid_document("vm006")
        vm006_allowed["allowed"] = [self.endpoint("1.1.1.1")]
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(vm006_allowed, "vm006-allowed.json")), "vm006")

    def test_rejects_profile_mismatch(self):
        with self.assertRaises(gateway_policy.PolicyError):
            gateway_policy.load_policy(str(self.write_policy(self.valid_document())), "vm004-bootstrap")

    def test_rules_are_default_drop_block_first_ipv6_drop_and_sut_only(self):
        policy = gateway_policy.load_policy(str(self.write_policy(self.valid_document())), "vm004-runtime")
        rules = gateway_policy.render_rules(policy, "wan0", "lan0")
        self.assertIn("type filter hook forward priority filter; policy drop;", rules)
        self.assertIn('iifname "lan0" meta nfproto ipv6 counter drop', rules)
        self.assertIn('iifname "lan0" ip saddr != 192.168.77.10 counter drop', rules)
        blocked = "ip daddr 8.8.8.8 tcp dport 443 counter drop"
        allowed = "ip daddr 1.1.1.1 tcp dport 8443 ct state new,established counter accept"
        self.assertIn(blocked, rules)
        self.assertIn(allowed, rules)
        self.assertLess(rules.index(blocked), rules.index(allowed))
        self.assertNotIn("0.0.0.0/0", rules)

    def test_vm004_rule_comments_are_unique_complete_and_policy_free(self):
        document = self.valid_document()
        document["blocked"].append(self.endpoint("9.9.9.9", "udp", 53))
        document["allowed"].append(self.endpoint("4.4.4.4", "tcp", 9443))
        policy = gateway_policy.load_policy(str(self.write_policy(document)), "vm004-runtime")
        rules = gateway_policy.render_rules(policy, "wan0", "lan0")
        comments = re.findall(r'comment "([^"]+)"', rules)
        expected = {
            "w11b-input-ipv6-drop",
            "w11b-input-non-sut-drop",
            "w11b-input-sut-drop",
            "w11b-forward-invalid-drop",
            "w11b-forward-ipv6-drop",
            "w11b-forward-non-sut-drop",
            "w11b-blocked-target-0001",
            "w11b-blocked-target-0002",
            "w11b-allowed-forward-0001",
            "w11b-allowed-forward-0002",
            "w11b-return-established-accept",
            "w11b-forward-default-drop",
            "w11b-masquerade",
        }
        self.assertEqual(expected, set(comments))
        self.assertEqual(len(expected), len(comments))
        for comment in comments:
            self.assertTrue(comment.startswith("w11b-"))
            self.assertNotIn(policy.profile, comment)
            self.assertNotIn("wan0", comment)
            self.assertNotIn("lan0", comment)
            for endpoint in policy.blocked + policy.allowed:
                self.assertNotIn(endpoint.address, comment)

    def test_vm006_rule_comments_cover_fault_proxy_and_forward_drop_once(self):
        policy = gateway_policy.load_policy(str(self.write_policy(self.valid_document("vm006"))), "vm006")
        rules = gateway_policy.render_rules(policy, "wan0", "lan0")
        comments = re.findall(r'comment "([^"]+)"', rules)
        expected = {
            "w11b-input-ipv6-drop",
            "w11b-input-non-sut-drop",
            "w11b-fault-proxy-input-accept",
            "w11b-fault-proxy-input-drop",
            "w11b-forward-invalid-drop",
            "w11b-forward-ipv6-drop",
            "w11b-forward-non-sut-drop",
            "w11b-blocked-target-0001",
            "w11b-forward-all-sut-drop",
            "w11b-return-established-accept",
            "w11b-forward-default-drop",
            "w11b-masquerade",
        }
        self.assertEqual(expected, set(comments))
        self.assertEqual(len(expected), len(comments))
        for comment in comments:
            self.assertNotIn(policy.profile, comment)
            self.assertNotIn(policy.blocked[0].address, comment)

    def test_vm006_allows_only_the_local_fault_proxy_input(self):
        policy = gateway_policy.load_policy(str(self.write_policy(self.valid_document("vm006"))), "vm006")
        rules = gateway_policy.render_rules(policy, "wan0", "lan0")
        self.assertIn("ip saddr 192.168.77.10 tcp dport 7897 counter accept", rules)
        forward = rules.split("chain forward", 1)[1].split("}", 1)[0]
        self.assertNotIn("counter accept", forward)

    def test_cli_creates_private_rules_and_outputs_only_hashes_and_counts(self):
        policy_path = self.write_policy(self.valid_document())
        rules_path = self.root / "rules.nft"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status_code = gateway_policy.main(
                [
                    "--policy",
                    str(policy_path),
                    "--profile",
                    "vm004-runtime",
                    "--wan-if",
                    "wan0",
                    "--lan-if",
                    "lan0",
                    "--rules-output",
                    str(rules_path),
                ]
            )
        self.assertEqual(0, status_code, stderr.getvalue())
        self.assertTrue(rules_path.is_file())
        self.assertEqual(0, stat.S_IMODE(rules_path.stat().st_mode) & 0o077)
        summary = stdout.getvalue()
        self.assertIn("policySha256=", summary)
        self.assertIn("rulesSha256=", summary)
        self.assertIn("blockedCount=1", summary)
        self.assertIn("allowedCount=1", summary)
        self.assertNotIn("8.8.8.8", summary)
        self.assertNotIn("1.1.1.1", summary)

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            second_status = gateway_policy.main(
                [
                    "--policy",
                    str(policy_path),
                    "--profile",
                    "vm004-runtime",
                    "--wan-if",
                    "wan0",
                    "--lan-if",
                    "lan0",
                    "--rules-output",
                    str(rules_path),
                ]
            )
        self.assertEqual(64, second_status)


if __name__ == "__main__":
    unittest.main()
