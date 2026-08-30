#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/w11b-configure-test.XXXXXXXX")"
FIXTURE_DIR="$TEST_ROOT/fixture"
CONFIGURE="$FIXTURE_DIR/configure_gateway.sh"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_RUN_ROOT="$TEST_ROOT/run"
FAKE_LOG="$TEST_ROOT/mutations.log"
RULES_CAPTURE="$TEST_ROOT/rules.capture"
FILTER_STATE_FILE="$TEST_ROOT/filter.state"
NAT_STATE_FILE="$TEST_ROOT/nat.state"
ADDRESS_STATE_FILE="$TEST_ROOT/address.state"
LINK_STATE_FILE="$TEST_ROOT/link.state"
SYSCTL_STATE_FILE="$TEST_ROOT/sysctl.state"
SYSCTL_POSTCHECK_FILE="$TEST_ROOT/sysctl-postcheck.state"
STDOUT_CAPTURE="$TEST_ROOT/stdout.txt"
STDERR_CAPTURE="$TEST_ROOT/stderr.txt"
POLICY="$TEST_ROOT/policy.json"
mkdir -p "$FIXTURE_DIR" "$FAKE_BIN" "$FAKE_RUN_ROOT"
cp -- "$SOURCE_DIR/configure_gateway.sh" "$CONFIGURE"
cp -- "$SOURCE_DIR/gateway_policy.py" "$FIXTURE_DIR/gateway_policy.py"
chmod 700 "$TEST_ROOT" "$FIXTURE_DIR" "$FAKE_BIN" "$FAKE_RUN_ROOT" "$CONFIGURE"
chmod 600 "$FIXTURE_DIR/gateway_policy.py"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail_test() {
  echo "test_configure_gateway.sh: $1" >&2
  exit 1
}

cat >"$FAKE_BIN/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "-o link show dev wan0") echo '2: wan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP' ;;
  "-o link show dev lan0")
    if [[ -f "$LINK_STATE_FILE" ]]; then
      echo '3: lan0: <BROADCAST,MULTICAST,UP> mtu 1500 state UP'
    else
      echo '3: lan0: <BROADCAST,MULTICAST> mtu 1500 state DOWN'
    fi
    ;;
  "-4 -o address show dev wan0 scope global") echo '2: wan0 inet 172.20.0.2/28 scope global wan0' ;;
  "-4 route show default dev wan0") echo 'default via 172.20.0.1 dev wan0' ;;
  "-4 route show default dev lan0"|"-6 -o address show dev lan0 scope global"|"-4 route show 192.168.77.0/24") ;;
  "-4 -o address show dev lan0 scope global"|"-4 -o address show to 192.168.77.1/32")
    [[ ! -f "$ADDRESS_STATE_FILE" ]] || echo '3: lan0 inet 192.168.77.1/24 scope global lan0'
    ;;
  "address add 192.168.77.1/24 dev lan0")
    echo 'MUTATE ip address add' >>"$FAKE_LOG"
    : >"$ADDRESS_STATE_FILE"
    ;;
  "address del 192.168.77.1/24 dev lan0")
    echo 'MUTATE ip address del' >>"$FAKE_LOG"
    if [[ "${ROLLBACK_ADDRESS_FAIL:-0}" != "1" ]]; then rm -f -- "$ADDRESS_STATE_FILE"; else exit 1; fi
    ;;
  "link set dev lan0 up")
    echo 'MUTATE ip link up' >>"$FAKE_LOG"
    : >"$LINK_STATE_FILE"
    ;;
  "link set dev lan0 down")
    echo 'MUTATE ip link down' >>"$FAKE_LOG"
    if [[ "${ROLLBACK_LINK_FAIL:-0}" != "1" ]]; then rm -f -- "$LINK_STATE_FILE"; else exit 1; fi
    ;;
  *) exit 90 ;;
esac
SH

cat >"$FAKE_BIN/sysctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "-n net.ipv4.ip_forward")
    if [[ -f "$SYSCTL_STATE_FILE" ]]; then
      if [[ ! -f "$SYSCTL_POSTCHECK_FILE" ]]; then
        : >"$SYSCTL_POSTCHECK_FILE"
        [[ "${POSTCHECK_FAIL:-0}" != "1" ]] && echo 1 || echo 0
      else
        echo 1
      fi
    else
      echo "${INITIAL_FORWARD:-0}"
    fi
    ;;
  "-n net.ipv6.conf.all.forwarding") echo "${INITIAL_IPV6_ALL_FORWARD:-0}" ;;
  "-n net.ipv6.conf.default.forwarding") echo "${INITIAL_IPV6_DEFAULT_FORWARD:-0}" ;;
  "-q -w net.ipv4.ip_forward=1")
    echo 'MUTATE sysctl forward=1' >>"$FAKE_LOG"
    rm -f -- "$SYSCTL_POSTCHECK_FILE"
    : >"$SYSCTL_STATE_FILE"
    ;;
  "-q -w net.ipv4.ip_forward=0")
    echo 'MUTATE sysctl forward=0' >>"$FAKE_LOG"
    if [[ "${ROLLBACK_FORWARD_FAIL:-0}" != "1" ]]; then
      rm -f -- "$SYSCTL_STATE_FILE" "$SYSCTL_POSTCHECK_FILE"
    else
      exit 1
    fi
    ;;
  *) exit 90 ;;
esac
SH

cat >"$FAKE_BIN/nft" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "list ruleset" ]]; then
  if [[ "${UNAPPROVED_NFT:-0}" == "1" ]]; then
    echo 'table inet unexpected { chain prerouting { type filter hook prerouting priority 0; policy accept; } }'
  elif [[ -f "$FILTER_STATE_FILE" || -f "$NAT_STATE_FILE" ]]; then
    [[ ! -f "$FILTER_STATE_FILE" ]] || echo 'table inet w11b_lab { chain forward { type filter hook forward priority filter; policy drop; } }'
    [[ ! -f "$NAT_STATE_FILE" ]] || echo 'table ip w11b_lab_nat { chain postrouting { type nat hook postrouting priority srcnat; } }'
  fi
  exit 0
fi
if [[ "$*" == "list tables" ]]; then
  [[ ! -f "$FILTER_STATE_FILE" ]] || echo 'table inet w11b_lab'
  [[ ! -f "$NAT_STATE_FILE" ]] || echo 'table ip w11b_lab_nat'
  exit 0
fi
if [[ "$*" == "list table inet w11b_lab" ]]; then
  [[ -f "$FILTER_STATE_FILE" ]] || exit 1
  echo 'table inet w11b_lab { chain forward { type filter hook forward priority filter; policy drop; } }'
  exit 0
fi
if [[ "${1:-}" == "--check" && "${2:-}" == "-f" ]]; then
  cp -- "$3" "$RULES_CAPTURE"
  exit 0
fi
if [[ "${1:-}" == "-f" ]]; then
  cp -- "$2" "$RULES_CAPTURE"
  echo 'MUTATE nft apply' >>"$FAKE_LOG"
  : >"$FILTER_STATE_FILE"
  : >"$NAT_STATE_FILE"
  exit 0
fi
if [[ "$*" == "delete table ip w11b_lab_nat" ]]; then
  echo 'MUTATE nft delete nat' >>"$FAKE_LOG"
  if [[ "${ROLLBACK_NAT_FAIL:-0}" != "1" ]]; then rm -f -- "$NAT_STATE_FILE"; else exit 1; fi
  exit 0
fi
if [[ "$*" == "delete table inet w11b_lab" ]]; then
  echo 'MUTATE nft delete filter' >>"$FAKE_LOG"
  if [[ "${ROLLBACK_FILTER_FAIL:-0}" != "1" ]]; then rm -f -- "$FILTER_STATE_FILE"; else exit 1; fi
  exit 0
fi
exit 90
SH

cat >"$FAKE_BIN/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${LISTENER_PRESENT:-0}" == "1" && "$*" == *"-ltn"* ]]; then
  echo 'LISTEN 0 1 192.168.77.1:7897 0.0.0.0:*'
fi
SH

cat >"$FAKE_BIN/iptables-save" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${UNAPPROVED_LEGACY:-0}" == "1" ]]; then
  printf '%s\n' '*nat' ':PREROUTING ACCEPT [0:0]' ':POSTROUTING ACCEPT [0:0]' 'COMMIT'
fi
SH
cp -- "$FAKE_BIN/iptables-save" "$FAKE_BIN/ip6tables-save"

cat >"$FAKE_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${PYTHONHOME:-}" == "" && "${PYTHONPATH:-}" == "" && "${PYTHONSTARTUP:-}" == "" &&
  "${PYTHONWARNINGS:-}" == "" ]] || exit 63
[[ "${1:-}" == "-I" && "${2:-}" == "-B" ]] || exit 63
shift 2
policy_path=""
rules_output=""
while (($# > 0)); do
  case "$1" in
    --policy) policy_path="$2"; shift 2 ;;
    --rules-output) rules_output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$policy_path" && -n "$rules_output" && ! -e "$rules_output" ]] || exit 64
cat >"$rules_output" <<'NFT'
table inet w11b_lab {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "lan0" meta nfproto ipv6 counter drop
    iifname "lan0" ip saddr != 192.168.77.10 counter drop
    iifname "lan0" ip saddr 192.168.77.10 counter drop
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    iifname "lan0" meta nfproto ipv6 counter drop
    iifname "lan0" ip saddr != 192.168.77.10 counter drop
    iifname "lan0" oifname "wan0" ip saddr 192.168.77.10 ip daddr 8.8.8.8 tcp dport 443 counter drop
    iifname "lan0" oifname "wan0" ip saddr 192.168.77.10 ip daddr 1.1.1.1 tcp dport 8443 ct state new,established counter accept
  }
}
table ip w11b_lab_nat {
  chain postrouting { type nat hook postrouting priority srcnat; policy accept; }
}
NFT
chmod 600 "$rules_output"
policy_hash="$(sha256sum < "$policy_path")"
rules_hash="$(sha256sum < "$rules_output")"
printf 'policySha256=%s rulesSha256=%s blockedCount=1 allowedCount=1\n' "${policy_hash%% *}" "${rules_hash%% *}"
SH

chmod 700 "$FAKE_BIN/ip" "$FAKE_BIN/sysctl" "$FAKE_BIN/nft" "$FAKE_BIN/ss" \
  "$FAKE_BIN/iptables-save" "$FAKE_BIN/ip6tables-save" "$FAKE_BIN/python3"

cat >"$POLICY" <<'JSON'
{"schemaVersion":1,"profile":"vm004-runtime","blocked":[{"address":"8.8.8.8","protocol":"tcp","port":443}],"allowed":[{"address":"1.1.1.1","protocol":"tcp","port":8443}]}
JSON
chmod 600 "$POLICY"

export FAKE_LOG RULES_CAPTURE FILTER_STATE_FILE NAT_STATE_FILE ADDRESS_STATE_FILE LINK_STATE_FILE \
  SYSCTL_STATE_FILE SYSCTL_POSTCHECK_FILE

TEST_COUNT=0

reset_case() {
  : >"$FAKE_LOG"
  rm -f -- "$RULES_CAPTURE" "$FILTER_STATE_FILE" "$NAT_STATE_FILE" "$ADDRESS_STATE_FILE" \
    "$LINK_STATE_FILE" "$SYSCTL_STATE_FILE" "$SYSCTL_POSTCHECK_FILE" "$STDOUT_CAPTURE" "$STDERR_CAPTURE"
  unset INITIAL_FORWARD INITIAL_IPV6_ALL_FORWARD INITIAL_IPV6_DEFAULT_FORWARD UNAPPROVED_NFT \
    UNAPPROVED_LEGACY LISTENER_PRESENT POSTCHECK_FAIL \
    ROLLBACK_FORWARD_FAIL ROLLBACK_ADDRESS_FAIL ROLLBACK_LINK_FAIL ROLLBACK_NAT_FAIL ROLLBACK_FILTER_FAIL
}

run_gateway() {
  set +e
  PYTHONHOME="$TEST_ROOT/injected-home" \
  PYTHONPATH="$TEST_ROOT/injected-path" \
  PYTHONSTARTUP="$TEST_ROOT/injected-startup" \
  PYTHONWARNINGS="error" \
  W11B_GATEWAY_TEST_MODE=1 \
  W11B_GATEWAY_TEST_PATH="$FAKE_BIN" \
  W11B_GATEWAY_TEST_RUN_ROOT="$FAKE_RUN_ROOT" \
  W11B_GATEWAY_TEST_TRUST_ROOT="$TEST_ROOT" \
  bash "$CONFIGURE" \
    --profile vm004-runtime \
    --wan-if wan0 \
    --lan-if lan0 \
    --policy "$POLICY" \
    >"$STDOUT_CAPTURE" 2>"$STDERR_CAPTURE"
  LAST_STATUS=$?
  set -e
}

test_unsafe_fixture_chain_fails_before_mutation() {
  local observed_mode numeric_mode
  reset_case
  chmod 770 "$TEST_ROOT"
  observed_mode="$(stat -c '%a' -- "$TEST_ROOT")"
  numeric_mode=$((8#$observed_mode))
  if (( (numeric_mode & 0020) == 0 )); then
    chmod 700 "$TEST_ROOT"
    echo "configure_gateway directory-chain mode test skipped: filesystem did not preserve group-write mode" >&2
    ((TEST_COUNT += 1))
    return
  fi
  run_gateway
  chmod 700 "$TEST_ROOT"
  ((LAST_STATUS != 0)) || fail_test "a group-writable fixture ancestor was accepted"
  assert_no_mutation
  ((TEST_COUNT += 1))
}

assert_no_mutation() {
  [[ ! -s "$FAKE_LOG" ]] || fail_test "a failed read-only gate performed a mutation"
}

if ((EUID == 0)); then
  reset_case
  run_gateway
  ((LAST_STATUS != 0)) || fail_test "root accepted test-mode injection"
  assert_no_mutation
  ((TEST_COUNT += 1))
  ((TEST_COUNT == 1)) || fail_test "root-mode test count is incomplete"
  echo "configure_gateway root injection refusal passed; non-root fake tests skipped"
  exit 0
fi

test_dirty_preflight_fails_before_mutation() {
  reset_case
  export INITIAL_FORWARD=1
  run_gateway
  ((LAST_STATUS != 0)) || fail_test "initial forwarding was accepted"
  assert_no_mutation
  ((TEST_COUNT += 1))

  reset_case
  export INITIAL_IPV6_ALL_FORWARD=1
  run_gateway
  ((LAST_STATUS != 0)) || fail_test "IPv6 all-interface forwarding was accepted"
  assert_no_mutation
  ((TEST_COUNT += 1))

  reset_case
  export INITIAL_IPV6_DEFAULT_FORWARD=1
  run_gateway
  ((LAST_STATUS != 0)) || fail_test "IPv6 default-interface forwarding was accepted"
  assert_no_mutation
  ((TEST_COUNT += 1))

  reset_case
  export UNAPPROVED_NFT=1
  run_gateway
  ((LAST_STATUS != 0)) || fail_test "unapproved nftables rules were accepted"
  assert_no_mutation
  ((TEST_COUNT += 1))

  reset_case
  export UNAPPROVED_LEGACY=1
  run_gateway
  ((LAST_STATUS != 0)) || fail_test "legacy NAT state was accepted"
  assert_no_mutation
  ((TEST_COUNT += 1))
}

test_success_has_block_before_allow_and_safe_summary() {
  reset_case
  run_gateway
  ((LAST_STATUS == 0)) || fail_test "valid configuration failed"
  rules="$(<"$RULES_CAPTURE")"
  [[ "$rules" == *"type filter hook forward priority filter; policy drop;"* ]] || fail_test "forward default-drop is missing"
  [[ "$rules" == *'iifname "lan0" meta nfproto ipv6 counter drop'* ]] || fail_test "IPv6 drop is missing"
  [[ "$rules" != *"0.0.0.0/0"* ]] || fail_test "a broad allow target was generated"
  blocked_line=0
  allowed_line=0
  line_number=0
  while IFS= read -r line; do
    ((line_number += 1))
    [[ "$line" != *"ip daddr 8.8.8.8 tcp dport 443 counter drop"* ]] || blocked_line=$line_number
    [[ "$line" != *"ip daddr 1.1.1.1 tcp dport 8443 ct state new,established counter accept"* ]] || allowed_line=$line_number
  done <"$RULES_CAPTURE"
  ((blocked_line > 0 && allowed_line > blocked_line)) || fail_test "blocked endpoints do not precede allowed endpoints"
  summary="$(<"$STDOUT_CAPTURE")"
  [[ "$summary" == policySha256=*" rulesSha256="*" blockedCount=1 allowedCount=1" ]] || fail_test "safe summary shape is invalid"
  [[ "$summary" != *"8.8.8.8"* && "$summary" != *"1.1.1.1"* ]] || fail_test "summary disclosed an endpoint"
  ((TEST_COUNT += 1))
}

test_successful_rollback_removes_filter_last() {
  reset_case
  export POSTCHECK_FAIL=1
  run_gateway
  ((LAST_STATUS == 70)) || fail_test "successful rollback changed the primary failure code"
  [[ ! -e "$FILTER_STATE_FILE" && ! -e "$NAT_STATE_FILE" && ! -e "$ADDRESS_STATE_FILE" && ! -e "$LINK_STATE_FILE" && ! -e "$SYSCTL_STATE_FILE" ]] ||
    fail_test "successful rollback left network state"
  mapfile -t mutations <"$FAKE_LOG"
  [[ "${mutations[-1]}" == 'MUTATE nft delete filter' ]] || fail_test "filter was not the final removed isolation boundary"
  ((TEST_COUNT += 1))
}

test_cleanup_failure_keeps_default_drop_and_returns_71() {
  local failure_variable="$1"
  local failure_label="$2"
  reset_case
  export POSTCHECK_FAIL=1
  printf -v "$failure_variable" '%s' 1
  export "$failure_variable"
  run_gateway
  ((LAST_STATUS == 71)) || fail_test "$failure_label cleanup failure did not use exit 71"
  [[ -e "$FILTER_STATE_FILE" ]] || fail_test "$failure_label cleanup failure removed the filter"
  grep -q 'hook forward priority filter; policy drop;' "$RULES_CAPTURE" ||
    fail_test "$failure_label cleanup failure lost the default-drop definition"
  if grep -q '^MUTATE nft delete filter$' "$FAKE_LOG"; then
    fail_test "$failure_label cleanup failure attempted filter deletion"
  fi
  ((TEST_COUNT += 1))
}

test_dirty_preflight_fails_before_mutation
test_unsafe_fixture_chain_fails_before_mutation
test_success_has_block_before_allow_and_safe_summary
test_successful_rollback_removes_filter_last
test_cleanup_failure_keeps_default_drop_and_returns_71 ROLLBACK_FORWARD_FAIL "IPv4 forwarding"
test_cleanup_failure_keeps_default_drop_and_returns_71 ROLLBACK_ADDRESS_FAIL "LAN address"
test_cleanup_failure_keeps_default_drop_and_returns_71 ROLLBACK_LINK_FAIL "LAN link"
test_cleanup_failure_keeps_default_drop_and_returns_71 ROLLBACK_NAT_FAIL "NAT"
((TEST_COUNT == 12)) || fail_test "expected 12 test cases but executed $TEST_COUNT"
echo "configure_gateway fail-closed tests passed"
