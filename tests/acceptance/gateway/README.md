# Gateway fault fixture

Use this fixture only inside the two-NIC Ubuntu Gateway VM described in the acceptance runbook. It never installs a CA or intercepts TLS. `fault_proxy.py` accepts only `CONNECT host:443` from `192.168.77.10`; its JSONL log contains time, client, target host/port, event type, and byte count only.

Set the two interface names after verifying them with `ip -brief link`, then run `configure_gateway.sh`. For VM-006A use `--mode reject-connect`. For VM-006B use `--mode probe-then-drop --probe-host <documented-probe-host>`. Always create a fresh log path because the proxy refuses to overwrite evidence.

The nftables table names are `w11b_lab` and `w11b_lab_nat`. Remove those two lab-only tables after the run; never apply this fixture on the physical host or the Windows SUT.
