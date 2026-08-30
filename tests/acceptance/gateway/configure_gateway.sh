#!/usr/bin/env bash
set -eEuo pipefail
IFS=$' \t\n'

readonly SUT_ADDRESS="192.168.77.10"
readonly LAN_ADDRESS="192.168.77.1/24"
readonly LAB_NETWORK="192.168.77.0/24"
readonly PROXY_PORT="7897"
readonly CLEANUP_FAILURE_EXIT=71
readonly PRODUCTION_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
readonly PRODUCTION_PYTHON="/usr/bin/python3"

fail() {
  local message="$1"
  local code="${2:-64}"
  echo "$message" >&2
  exit "$code"
}

usage() {
  echo "usage: configure_gateway.sh --profile PROFILE --wan-if IF --lan-if IF --policy PRIVATE_JSON" >&2
  exit 64
}

# Production never consumes an injected PATH or temporary root.  The explicit
# injection surface exists only so an actual non-root process can run the
# command-fake tests; root refuses it before invoking any external command.
TEST_MODE="${W11B_GATEWAY_TEST_MODE:-}"
if ((EUID == 0)); then
  [[ -z "$TEST_MODE" ]] || fail "root refuses Gateway test-mode injection"
  PATH="$PRODUCTION_PATH"
  RUN_ROOT="/run"
  PYTHON_BIN="$PRODUCTION_PYTHON"
  TRUST_CHAIN_STOP="/"
else
  [[ "$TEST_MODE" == "1" ]] || fail "run the Gateway configuration as root"
  TEST_PATH="${W11B_GATEWAY_TEST_PATH:-}"
  RUN_ROOT="${W11B_GATEWAY_TEST_RUN_ROOT:-}"
  TEST_TRUST_ROOT="${W11B_GATEWAY_TEST_TRUST_ROOT:-}"
  [[ "$TEST_PATH" == /* && "$RUN_ROOT" == /* && "$TEST_TRUST_ROOT" == /* ]] ||
    fail "test-mode paths must be absolute"
  [[ -d "$TEST_PATH" && ! -L "$TEST_PATH" && -d "$RUN_ROOT" && ! -L "$RUN_ROOT" &&
    -d "$TEST_TRUST_ROOT" && ! -L "$TEST_TRUST_ROOT" ]] ||
    fail "test-mode paths must be plain directories"
  PATH="$TEST_PATH:$PRODUCTION_PATH"
  PYTHON_BIN="$TEST_PATH/python3"
  TRUST_CHAIN_STOP="$(cd -- "$TEST_TRUST_ROOT" && pwd -P)"
fi
export PATH
unset CDPATH ENV BASH_ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONWARNINGS

PROFILE=""
WAN_IF=""
LAN_IF=""
POLICY_PATH=""
while (($# > 0)); do
  case "$1" in
    --profile)
      (($# >= 2)) || usage
      [[ -z "$PROFILE" ]] || fail "profile was specified more than once"
      PROFILE="$2"
      shift 2
      ;;
    --wan-if)
      (($# >= 2)) || usage
      [[ -z "$WAN_IF" ]] || fail "WAN interface was specified more than once"
      WAN_IF="$2"
      shift 2
      ;;
    --lan-if)
      (($# >= 2)) || usage
      [[ -z "$LAN_IF" ]] || fail "LAN interface was specified more than once"
      LAN_IF="$2"
      shift 2
      ;;
    --policy)
      (($# >= 2)) || usage
      [[ -z "$POLICY_PATH" ]] || fail "policy was specified more than once"
      POLICY_PATH="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$PROFILE" && -n "$WAN_IF" && -n "$LAN_IF" && -n "$POLICY_PATH" ]] || usage
case "$PROFILE" in
  vm004-bootstrap|vm004-subscription|vm004-runtime|vm006) ;;
  *) fail "unsupported Gateway profile" ;;
esac
[[ "$WAN_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ && "$LAN_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] ||
  fail "interface names use unsupported characters"
[[ "$WAN_IF" != "$LAN_IF" ]] || fail "WAN and LAN interfaces must differ"

for required_command in ip sysctl nft ss mktemp dirname chmod rm rmdir stat sha256sum iptables-save ip6tables-save; do
  command -v "$required_command" >/dev/null 2>&1 || fail "a required Gateway command is unavailable"
done
[[ -f "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || fail "the fixed Gateway Python interpreter is unavailable"

SOURCE_PATH="${BASH_SOURCE[0]}"
[[ -f "$SOURCE_PATH" && ! -L "$SOURCE_PATH" ]] || fail "Gateway configuration script is missing or unsafe"
SOURCE_DIRECTORY="${SOURCE_PATH%/*}"
[[ "$SOURCE_DIRECTORY" != "$SOURCE_PATH" ]] || SOURCE_DIRECTORY="."
SCRIPT_DIR="$(cd -- "$SOURCE_DIRECTORY" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/${SOURCE_PATH##*/}"
POLICY_TOOL="$SCRIPT_DIR/gateway_policy.py"

validate_trusted_file() {
  local path="$1"
  local metadata owner mode extra numeric_mode
  [[ -f "$path" && ! -L "$path" ]] || return 1
  metadata="$(stat -c '%u %a' -- "$path" 2>/dev/null)" || return 1
  read -r owner mode extra <<< "$metadata"
  [[ -z "${extra:-}" && "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$owner" == "$EUID" ]] || return 1
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 0022) == 0 ))
}

validate_trusted_directory() {
  local path="$1"
  local metadata owner mode extra numeric_mode
  [[ -d "$path" && ! -L "$path" ]] || return 1
  metadata="$(stat -c '%u %a' -- "$path" 2>/dev/null)" || return 1
  read -r owner mode extra <<< "$metadata"
  [[ -z "${extra:-}" && "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$owner" == "$EUID" ]] || return 1
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 0022) == 0 ))
}

validate_trusted_directory_chain() {
  local current="$1"
  local stop="$2"
  local parent
  [[ "$current" == /* && "$stop" == /* ]] || return 1
  while true; do
    validate_trusted_directory "$current" || return 1
    [[ "$current" == "$stop" ]] && return 0
    [[ "$current" != "/" ]] || return 1
    parent="$(dirname -- "$current")" || return 1
    [[ "$parent" != "$current" ]] || return 1
    current="$parent"
  done
}

validate_trusted_directory_chain "$SCRIPT_DIR" "$TRUST_CHAIN_STOP" ||
  fail "Gateway fixture directory chain ownership or mode is unsafe"
validate_trusted_file "$SCRIPT_PATH" || fail "Gateway configuration script ownership or mode is unsafe"
validate_trusted_file "$POLICY_TOOL" || fail "Gateway policy helper ownership or mode is unsafe"
validate_trusted_directory "$RUN_ROOT" || fail "Gateway runtime directory ownership or mode is unsafe"

TEMP_DIR="$(mktemp -d -- "$RUN_ROOT/w11b-gateway.XXXXXXXX")" || fail "unable to create a private temporary directory"
chmod 700 "$TEMP_DIR"
validate_trusted_directory "$TEMP_DIR" || fail "private temporary directory validation failed"
RULES_PATH="$TEMP_DIR/rules.nft"

MUTATION_STARTED=0
FILTER_MAY_EXIST=0
NAT_MAY_EXIST=0
ADDRESS_MAY_EXIST=0
LINK_MAY_HAVE_CHANGED=0
FORWARD_MAY_HAVE_CHANGED=0
LAN_WAS_UP=0

table_exists() {
  local family="$1"
  local wanted="$2"
  local listing keyword listed_family listed_name remainder
  listing="$(nft list tables 2>/dev/null)" || return 2
  while read -r keyword listed_family listed_name remainder; do
    if [[ "$keyword" == "table" && "$listed_family" == "$family" && "$listed_name" == "$wanted" ]]; then
      return 0
    fi
  done <<< "$listing"
  return 1
}

link_is_up() {
  local interface="$1"
  local link flags
  link="$(ip -o link show dev "$interface" 2>/dev/null)" || return 2
  [[ "$link" =~ \<([^\>]*)\> ]] || return 2
  flags=",${BASH_REMATCH[1]},"
  [[ "$flags" == *,UP,* ]]
}

rollback() {
  local cleanup_failed=0
  local observed table_status filter_rules
  set +e

  if ((FORWARD_MAY_HAVE_CHANGED)); then
    sysctl -q -w net.ipv4.ip_forward=0 >/dev/null 2>&1
    observed="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    [[ "$observed" == "0" ]] || cleanup_failed=1
  fi

  if ((ADDRESS_MAY_EXIST)); then
    ip address del "$LAN_ADDRESS" dev "$LAN_IF" >/dev/null 2>&1
    observed="$(ip -4 -o address show dev "$LAN_IF" scope global 2>/dev/null)"
    [[ -z "$observed" ]] || cleanup_failed=1
  fi

  if ((LINK_MAY_HAVE_CHANGED)); then
    ip link set dev "$LAN_IF" down >/dev/null 2>&1
    link_is_up "$LAN_IF"
    table_status=$?
    [[ "$table_status" == "1" ]] || cleanup_failed=1
  fi

  if ((NAT_MAY_EXIST)); then
    table_exists ip w11b_lab_nat
    table_status=$?
    if ((table_status == 0)); then
      nft delete table ip w11b_lab_nat >/dev/null 2>&1
    elif ((table_status == 2)); then
      cleanup_failed=1
    fi
    table_exists ip w11b_lab_nat
    table_status=$?
    [[ "$table_status" == "1" ]] || cleanup_failed=1
  fi

  # The filter is the final isolation boundary.  It is deleted only after
  # forwarding, address, link, and NAT restoration all independently verify.
  if ((cleanup_failed == 0 && FILTER_MAY_EXIST)); then
    table_exists inet w11b_lab
    table_status=$?
    if ((table_status == 0)); then
      nft delete table inet w11b_lab >/dev/null 2>&1
    elif ((table_status == 2)); then
      cleanup_failed=1
    fi
    table_exists inet w11b_lab
    table_status=$?
    [[ "$table_status" == "1" ]] || cleanup_failed=1
  elif ((FILTER_MAY_EXIST)); then
    table_exists inet w11b_lab
    table_status=$?
    if ((table_status == 0)); then
      filter_rules="$(nft list table inet w11b_lab 2>/dev/null)"
      [[ "$filter_rules" == *"hook forward"* && "$filter_rules" == *"policy drop"* ]] || cleanup_failed=1
    elif ((table_status == 2)); then
      cleanup_failed=1
    fi
  fi

  set -e
  ((cleanup_failed == 0))
}

finish() {
  local status=$?
  local temp_failed=0
  trap - EXIT
  trap '' HUP INT TERM
  if ((status != 0 && MUTATION_STARTED)); then
    if ! rollback; then
      status=$CLEANUP_FAILURE_EXIT
      echo "Gateway rollback could not verify every isolation invariant; filter deletion was withheld." >&2
    fi
  fi
  rm -f -- "$RULES_PATH" || temp_failed=1
  rmdir -- "$TEMP_DIR" >/dev/null 2>&1 || temp_failed=1
  if ((temp_failed)); then
    status=$CLEANUP_FAILURE_EXIT
    echo "Gateway private temporary cleanup failed." >&2
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM

legacy_rules_are_approved() {
  local content="$1"
  local state="start"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$state" in
      start)
        [[ "$line" == "*filter" ]] || return 1
        state="filter"
        ;;
      filter)
        [[ "$line" =~ ^:INPUT[[:space:]]+ACCEPT[[:space:]]+\[[0-9]+:[0-9]+\]$ ]] || return 1
        state="input"
        ;;
      input)
        [[ "$line" =~ ^:FORWARD[[:space:]]+ACCEPT[[:space:]]+\[[0-9]+:[0-9]+\]$ ]] || return 1
        state="forward"
        ;;
      forward)
        [[ "$line" =~ ^:OUTPUT[[:space:]]+ACCEPT[[:space:]]+\[[0-9]+:[0-9]+\]$ ]] || return 1
        state="output"
        ;;
      output)
        [[ "$line" == "COMMIT" ]] || return 1
        state="done"
        ;;
      done) return 1 ;;
    esac
  done <<< "$content"
  [[ "$state" == "start" || "$state" == "done" ]]
}

# Every command through nft --check is a read-only gate.  No network state may
# be changed above the mutation marker below.
if ! WAN_LINK="$(ip -o link show dev "$WAN_IF" 2>/dev/null)" || [[ -z "$WAN_LINK" ]]; then
  fail "WAN interface was not found"
fi
if ! LAN_LINK="$(ip -o link show dev "$LAN_IF" 2>/dev/null)" || [[ -z "$LAN_LINK" ]]; then
  fail "LAN interface was not found"
fi
if link_is_up "$LAN_IF"; then
  LAN_WAS_UP=1
else
  link_status=$?
  [[ "$link_status" == "1" ]] || fail "LAN administrative state could not be determined"
fi
if ! WAN_ADDRESSES="$(ip -4 -o address show dev "$WAN_IF" scope global 2>/dev/null)" || [[ -z "$WAN_ADDRESSES" ]]; then
  fail "WAN interface has no global IPv4 address"
fi
if ! WAN_DEFAULT="$(ip -4 route show default dev "$WAN_IF" 2>/dev/null)" || [[ -z "$WAN_DEFAULT" ]]; then
  fail "WAN interface has no IPv4 default route"
fi
if ! LAN_DEFAULT="$(ip -4 route show default dev "$LAN_IF" 2>/dev/null)"; then
  fail "LAN route state could not be inspected"
fi
[[ -z "$LAN_DEFAULT" ]] || fail "LAN interface must not have a default route"
if ! LAN_IPV4="$(ip -4 -o address show dev "$LAN_IF" scope global 2>/dev/null)"; then
  fail "LAN IPv4 state could not be inspected"
fi
[[ -z "$LAN_IPV4" ]] || fail "LAN interface already has a global IPv4 address"
if ! LAN_IPV6="$(ip -6 -o address show dev "$LAN_IF" scope global 2>/dev/null)"; then
  fail "LAN IPv6 state could not be inspected"
fi
[[ -z "$LAN_IPV6" ]] || fail "LAN interface already has a global IPv6 address"
if ! ADDRESS_CONFLICT="$(ip -4 -o address show to 192.168.77.1/32 2>/dev/null)"; then
  fail "lab address ownership could not be inspected"
fi
[[ -z "$ADDRESS_CONFLICT" ]] || fail "lab Gateway address already exists"
if ! ROUTE_CONFLICT="$(ip -4 route show "$LAB_NETWORK" 2>/dev/null)"; then
  fail "lab route state could not be inspected"
fi
[[ -z "$ROUTE_CONFLICT" ]] || fail "lab network route already exists"

if ! ORIGINAL_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"; then
  fail "IPv4 forwarding state could not be inspected"
fi
[[ "$ORIGINAL_FORWARD" == "0" ]] || fail "IPv4 forwarding must initially be disabled"
if ! ORIGINAL_IPV6_ALL_FORWARD="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)"; then
  fail "IPv6 all-interface forwarding state could not be inspected"
fi
[[ "$ORIGINAL_IPV6_ALL_FORWARD" == "0" ]] || fail "IPv6 all-interface forwarding must be integer 0"
if ! ORIGINAL_IPV6_DEFAULT_FORWARD="$(sysctl -n net.ipv6.conf.default.forwarding 2>/dev/null)"; then
  fail "IPv6 default-interface forwarding state could not be inspected"
fi
[[ "$ORIGINAL_IPV6_DEFAULT_FORWARD" == "0" ]] || fail "IPv6 default-interface forwarding must be integer 0"

if ! NFT_BASELINE="$(nft list ruleset 2>/dev/null)"; then
  fail "nftables state could not be inspected"
fi
NFT_COMPACT="${NFT_BASELINE//[[:space:]]/}"
[[ -z "$NFT_COMPACT" ]] || fail "nftables ruleset is not an approved empty baseline"
if ! IPTABLES_BASELINE="$(iptables-save 2>/dev/null)" || ! legacy_rules_are_approved "$IPTABLES_BASELINE"; then
  fail "iptables contains unapproved forwarding or NAT state"
fi
if ! IP6TABLES_BASELINE="$(ip6tables-save 2>/dev/null)" || ! legacy_rules_are_approved "$IP6TABLES_BASELINE"; then
  fail "ip6tables contains unapproved forwarding or NAT state"
fi

if ! TCP_LISTENERS="$(ss -H -ltn "sport = :$PROXY_PORT" 2>/dev/null)"; then
  fail "TCP listener state could not be inspected"
fi
if ! UDP_LISTENERS="$(ss -H -lun "sport = :$PROXY_PORT" 2>/dev/null)"; then
  fail "UDP listener state could not be inspected"
fi
[[ -z "$TCP_LISTENERS" && -z "$UDP_LISTENERS" ]] || fail "Gateway proxy port is already in use"

if TOOL_SUMMARY="$(
  "$PYTHON_BIN" -I -B "$POLICY_TOOL" \
    --policy "$POLICY_PATH" \
    --profile "$PROFILE" \
    --wan-if "$WAN_IF" \
    --lan-if "$LAN_IF" \
    --rules-output "$RULES_PATH"
)"; then
  :
else
  policy_status=$?
  exit "$policy_status"
fi
validate_trusted_file "$RULES_PATH" || fail "private rules output ownership or mode is unsafe"
SUMMARY_PATTERN='^policySha256=([0-9a-f]{64}) rulesSha256=([0-9a-f]{64}) blockedCount=([1-9][0-9]*) allowedCount=(0|[1-9][0-9]*)$'
[[ "$TOOL_SUMMARY" =~ $SUMMARY_PATTERN ]] || fail "Gateway policy summary shape is invalid"
TOOL_POLICY_HASH="${BASH_REMATCH[1]}"
TOOL_RULES_HASH="${BASH_REMATCH[2]}"
BLOCKED_COUNT="${BASH_REMATCH[3]}"
ALLOWED_COUNT="${BASH_REMATCH[4]}"
if [[ "$PROFILE" == "vm006" ]]; then
  [[ "$ALLOWED_COUNT" == "0" ]] || fail "vm006 policy summary is inconsistent"
else
  ((ALLOWED_COUNT > 0)) || fail "vm004 policy summary is inconsistent"
fi
POLICY_HASH_LINE="$(sha256sum < "$POLICY_PATH")" || fail "policy hash could not be rebuilt"
RULES_HASH_LINE="$(sha256sum < "$RULES_PATH")" || fail "rules hash could not be rebuilt"
POLICY_HASH="${POLICY_HASH_LINE%% *}"
RULES_HASH="${RULES_HASH_LINE%% *}"
[[ "$POLICY_HASH" == "$TOOL_POLICY_HASH" && "$RULES_HASH" == "$TOOL_RULES_HASH" ]] ||
  fail "Gateway policy summary hashes could not be reproduced"
POLICY_SUMMARY="policySha256=$POLICY_HASH rulesSha256=$RULES_HASH blockedCount=$BLOCKED_COUNT allowedCount=$ALLOWED_COUNT"
if ! nft --check -f "$RULES_PATH" >/dev/null 2>&1; then
  fail "generated nftables rules failed syntax validation"
fi
CURRENT_POLICY_HASH_LINE="$(sha256sum < "$POLICY_PATH")" || fail "policy freshness hash failed"
CURRENT_RULES_HASH_LINE="$(sha256sum < "$RULES_PATH")" || fail "rules freshness hash failed"
[[ "${CURRENT_POLICY_HASH_LINE%% *}" == "$POLICY_HASH" && "${CURRENT_RULES_HASH_LINE%% *}" == "$RULES_HASH" ]] ||
  fail "policy or rules changed before application"

# Intent flags are set before each external mutation.  Bash may deliver a
# signal after an external command and before the next statement; pre-setting
# the flag closes that ownership/rollback window, while rollback verifies the
# actual resulting state before removing the final filter.
MUTATION_STARTED=1
FILTER_MAY_EXIST=1
NAT_MAY_EXIST=1
if ! nft -f "$RULES_PATH" >/dev/null 2>&1; then
  fail "nftables policy could not be applied" 70
fi
ADDRESS_MAY_EXIST=1
if ! ip address add "$LAN_ADDRESS" dev "$LAN_IF" >/dev/null 2>&1; then
  fail "lab address could not be applied" 70
fi
if ((LAN_WAS_UP == 0)); then
  LINK_MAY_HAVE_CHANGED=1
  if ! ip link set dev "$LAN_IF" up >/dev/null 2>&1; then
    fail "LAN interface could not be enabled" 70
  fi
fi
FORWARD_MAY_HAVE_CHANGED=1
if ! sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
  fail "IPv4 forwarding could not be enabled" 70
fi
if ! APPLIED_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" || [[ "$APPLIED_FORWARD" != "1" ]]; then
  fail "IPv4 forwarding did not remain enabled" 70
fi

printf '%s\n' "$POLICY_SUMMARY"
