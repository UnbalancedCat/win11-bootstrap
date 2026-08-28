#!/usr/bin/env bash
set -euo pipefail

: "${W11B_WAN_IF:?set W11B_WAN_IF to the Default Switch interface}"
: "${W11B_LAN_IF:?set W11B_LAN_IF to the W11B-Lab interface}"

if [[ "${W11B_WAN_IF}" == "${W11B_LAN_IF}" ]]; then
  echo "WAN and LAN interfaces must differ" >&2
  exit 64
fi
for interface in "${W11B_WAN_IF}" "${W11B_LAN_IF}"; do
  if ! ip link show dev "${interface}" >/dev/null 2>&1; then
    echo "Interface not found: ${interface}" >&2
    exit 64
  fi
done

sudo ip address replace 192.168.77.1/24 dev "${W11B_LAN_IF}"
sudo ip link set dev "${W11B_LAN_IF}" up
sudo sysctl -w net.ipv4.ip_forward=1
sudo nft -f - <<NFT
table inet w11b_lab {
  chain forward {
    type filter hook forward priority filter; policy drop;
    iifname "${W11B_LAN_IF}" oifname "${W11B_WAN_IF}" ip saddr 192.168.77.10 ct state new,established,related accept
    iifname "${W11B_WAN_IF}" oifname "${W11B_LAN_IF}" ip daddr 192.168.77.10 ct state established,related accept
  }
}
table ip w11b_lab_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${W11B_WAN_IF}" ip saddr 192.168.77.10 masquerade
  }
}
NFT

echo "Gateway configured for the isolated 192.168.77.0/24 lab only."
