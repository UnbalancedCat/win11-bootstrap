# Gateway fault fixture

Use this fixture only inside the two-NIC Ubuntu Gateway VM described in the acceptance runbook. WAN connects to Default Switch, LAN connects to private switch `W11B-Lab`, the Gateway LAN address is `192.168.77.1/24`, and the only accepted SUT address is `192.168.77.10`. During VM-004/006 the SUT must have only the `W11B-Lab` adapter, no alternative route, no usable global IPv6 address, and no global or default IPv6 route. The generated rules drop LAN IPv6 and traffic from every other client.

The fixture never installs a CA or intercepts TLS. It does not authorize a persistent host or SUT proxy, certificate, firewall, WinHTTP, system-proxy, or TUN change. `fault_proxy.py` accepts only credential-free `CONNECT host:443` from `192.168.77.10` on `192.168.77.1:7897`; every JSONL record contains only `timestamp`, `role`, `event`, and `bytes`, never a client address, target host/port, header, or body.

## Private policy gate

Before every profile, restore the powered-off clean Gateway baseline, verify the WAN/LAN interface identities and state, then configure exactly one profile:

```sh
sudo ./configure_gateway.sh --profile vm004-bootstrap --wan-if <WAN_IF> --lan-if <LAN_IF> --policy /var/lib/w11b-private/v0.1.0/VM-004/chrome-vm004-bootstrap.json
sudo ./configure_gateway.sh --profile vm004-subscription --wan-if <WAN_IF> --lan-if <LAN_IF> --policy /var/lib/w11b-private/v0.1.0/VM-004/chrome-vm004-subscription.json
sudo ./configure_gateway.sh --profile vm004-runtime --wan-if <WAN_IF> --lan-if <LAN_IF> --policy /var/lib/w11b-private/v0.1.0/VM-004/chrome-vm004-runtime.json
sudo ./configure_gateway.sh --profile vm006 --wan-if <WAN_IF> --lan-if <LAN_IF> --policy /var/lib/w11b-private/v0.1.0/VM-006/a-network.json
```

Each JSON path is fixed for the scenario/leg/profile and must be create-new, a regular non-symlink file owned by the invoking EUID, and mode `0600`. Production configuration runs under `sudo`, so the production network policy must be root-owned. The strict network schema contains `schemaVersion`, the exact `profile`, and `blocked`/`allowed` arrays. Every endpoint is one canonical public IPv4 address plus an exact `tcp` or `udp` protocol and exact port; do not use a hostname, CIDR, range, wildcard, or unresolved target. `vm006` permits no forwarded endpoint. The script refuses pre-existing fixture tables, a listener collision, unsafe LAN state, or an invalid policy before applying changes.

The private policy and generated rules are not evidence. Never copy them to an evidence VHDX, repository, handoff, or GitHub. Record only the reported policy/rules SHA-256 values, blocked/allowed counts, redacted nftables counters, and the state hashes needed by the manifest. For Clash-bearing policies, never disclose a subscription, node, node address, or the association between a node and an IP address.

## Redacted state capture

Install the frozen toolkit's `capture_gateway_state.py`, `configure_gateway.sh`, `fault_proxy.py`, and `gateway_policy.py` in a dedicated real, non-symlink directory such as `/opt/w11b-gateway-fixture`. That directory and every directory in its resolved path to `/` must be root-owned and not writable by group or other users; all four allowlisted entries must be root-owned regular non-symlink files with the same write restriction. Production capture must run as root through `/usr/bin/python3 -I -B`; the imported `gateway_policy.py` and `fault_proxy.py` must resolve to that exact trusted fixture. The selected network policy must also be a root-owned, non-symlink `0600` file whose embedded profile matches the required `--profile`.

Create one trusted evidence parent for the scenario before capture. Each `--output` must be a direct child of that real, non-symlink directory; the parent must be root-owned and not writable by group or other users. The output must not exist and is created root-owned as `0600` only after all read-only gates succeed. This collector checks the guest-visible POSIX parent and records its identity hash; it does not prove that the mount is backed by the approved private host NTFS evidence VHDX. Verify the VHDX attachment and mount separately at the host boundary before formal evidence begins.

For VM-004, pass the exact matching `vm004-bootstrap`, `vm004-subscription`, or `vm004-runtime` profile and omit `--ready-file`. The following example is the runtime leg; repeat it with distinct direct-child output names around the SUT operation:

```sh
sudo /usr/bin/python3 -I -B /opt/w11b-gateway-fixture/capture_gateway_state.py --output <TRUSTED_EVIDENCE_PARENT>/gateway-before.json --fixture-root /opt/w11b-gateway-fixture --policy /var/lib/w11b-private/v0.1.0/VM-004/chrome-vm004-runtime.json --profile vm004-runtime --wan-interface <WAN_IF> --lan-interface <LAN_IF>
sudo /usr/bin/python3 -I -B /opt/w11b-gateway-fixture/capture_gateway_state.py --output <TRUSTED_EVIDENCE_PARENT>/gateway-after.json --fixture-root /opt/w11b-gateway-fixture --policy /var/lib/w11b-private/v0.1.0/VM-004/chrome-vm004-runtime.json --profile vm004-runtime --wan-interface <WAN_IF> --lan-interface <LAN_IF>
```

VM-004 rejects a `--ready-file` and fails if any TCP or UDP socket is bound to port 7897 anywhere on the Gateway. The local Clash listener belongs only on the Windows SUT.

For VM-006, first start the exact root-owned fixture process documented below and wait for its create-new ready file. Both captures must use the `vm006` network policy and the same `--ready-file`, while the proxy remains running:

```sh
sudo /usr/bin/python3 -I -B /opt/w11b-gateway-fixture/capture_gateway_state.py --output <TRUSTED_EVIDENCE_PARENT>/gateway-before.json --fixture-root /opt/w11b-gateway-fixture --policy /var/lib/w11b-private/v0.1.0/VM-006/a-network.json --profile vm006 --wan-interface <WAN_IF> --lan-interface <LAN_IF> --ready-file <TRUSTED_EVIDENCE_PARENT>/gateway-ready.json
sudo /usr/bin/python3 -I -B /opt/w11b-gateway-fixture/capture_gateway_state.py --output <TRUSTED_EVIDENCE_PARENT>/gateway-after.json --fixture-root /opt/w11b-gateway-fixture --policy /var/lib/w11b-private/v0.1.0/VM-006/a-network.json --profile vm006 --wan-interface <WAN_IF> --lan-interface <LAN_IF> --ready-file <TRUSTED_EVIDENCE_PARENT>/gateway-ready.json
```

The collector rejects every NIC inventory except unique loopback, WAN, and LAN links. It inventories all addresses, every IPv4/IPv6 route in all standard tables, and both IP policy-rule families; WAN must have exactly one IPv4 default route, LAN/loopback must have none, and policy rules must be exactly `local`, `main`, and `default`. IPv4 forwarding must be 1 while both all-interface and default-interface IPv6 forwarding are 0. The nftables ruleset must contain exactly the two fixture tables, three chains with their frozen hook/priority/policy values, and the selected policy's complete ordered rules with exact matches, counters, verdicts, and NAT semantics. Missing, extra, duplicate, uncommented, reordered, or semantically different entities fail closed.

For VM-006, exactly one `tcp LISTEN` socket must bind `192.168.77.1:7897`. It must resolve through `/proc` to a root-owned system `/usr/bin/python3` process with all UIDs 0, the exact frozen `fault_proxy.py --policy ... --log ... --ready-file ...` argv, and root-owned `0600` active policy, log, and ready files. The ready profile/hash must match that live process. A listening port without this process identity is failure.

The document contains fixture and policy hashes, redacted complete-network identities, forwarding state, legacy-firewall hashes, exact nftables structure hash/counters, and the validated listener/process identity. It contains no raw policy, raw WAN address or route, raw MAC, interface name, or private fixture/policy path. Compare before/after identity fields and review the expected counter deltas; timestamps and counters are not expected to be byte-identical. Any unexplained policy, fixture, network, forwarding, firewall, ruleset, ready, or listener/process drift blocks the scenario.

## VM-004

Run two isolated Ready-target legs from the same clean Windows gold and clean Gateway checkpoint:

- `chrome`: exercise local Clash automatic discovery at `127.0.0.1:7897`; do not pass `-ProxyUri` to the candidate.
- `bandizip`: explicitly pass `-ProxyUri http://127.0.0.1:7897`.

For each leg, use create-new private policies and repeat this sequence independently:

1. From clean Gateway, apply `vm004-bootstrap`. Permit only exact Clash bootstrap endpoints and block the selected Ready target. The candidate installs Clash while the selected target returns `NeedsProxy/10`.
2. Restore clean Gateway and apply `vm004-subscription`. Enter the subscription only in the Clash UI with system proxy and TUN disabled. The policy exposes only the exact endpoints needed for this phase.
3. Restore clean Gateway and apply `vm004-runtime`. Permit only exact frozen Clash-node endpoints while continuing to block the target's direct endpoint set, then run the selected target through the required local-proxy path.
4. Capture the reported hashes/counts, redacted nftables counters, and SUT network/proxy state. After evidence extraction, destroy the subscription-bearing SUT branch and restore the clean Gateway checkpoint.

One Ready-target leg must not inherit state from the other. Policy contents and Clash subscription/node data never enter evidence.

## VM-006

VM-006A and VM-006B are independent clean restores. For each branch, apply a create-new root-owned `vm006` network policy, then start the proxy in a dedicated terminal with the frozen root-owned fixture and create-new root-owned `0600` log and ready-file paths:

```sh
sudo /usr/bin/python3 -I -B /opt/w11b-gateway-fixture/fault_proxy.py --policy /var/lib/w11b-private/v0.1.0/VM-006/vm006a-proxy.json --log <TRUSTED_EVIDENCE_PARENT>/gateway-events.jsonl --ready-file <TRUSTED_EVIDENCE_PARENT>/gateway-ready.json
```

The frozen probe is `https://www.microsoft.com/favicon.ico`, host `www.microsoft.com`. On the SUT, always address this Gateway explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Test-ExplicitProxyHttps.ps1 -ProxyUri http://192.168.77.1:7897 -Uri https://www.microsoft.com/favicon.ico
```

The candidate invocation also explicitly passes `-ProxyUri http://192.168.77.1:7897` with `-Only chrome`.

- VM-006A uses a create-new `vm006a` proxy policy containing exactly one `www.microsoft.com` probe rule with action `reject` and an empty upstream-address list. The probe fails and the candidate returns `NeedsProxy/10`.
- VM-006B uses a create-new `vm006b` policy. The probe rule is `relay`, at least one frozen metadata host is `relay`, and at least one frozen payload host is `drop`; every relay/drop rule pins one or more reviewed canonical public IP addresses. The probe succeeds, metadata relay is observed, and the later payload transfer is dropped after 65536 bytes, leaving Chrome absent and returning `NeedsProxy/10`.

Capture the ready metadata, policy hash and rule count, redacted nftables counters, Gateway state before/after, and JSONL event types/byte counts. Do not copy either private proxy policy into evidence. Before and after values for WinGet feature, WinINET, WinHTTP, environment, firewall, SUT adapters, IPv4/IPv6, DNS, and routes must match.

After evidence extraction, shut down and restore the clean Gateway checkpoint. Do not manually delete `w11b_lab` or `w11b_lab_nat`; checkpoint restoration is the cleanup and drift boundary.
