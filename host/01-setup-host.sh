#!/usr/bin/env bash
# Run once (or after reboot) with: sudo ./01-setup-host.sh
# The VM network itself (br-kali + IP + DHCP) is owned by libvirt (kali-net,
# autostarted). This script only handles firewall + forwarding.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

BR=br-kali
VMNET=10.170.0.0/24
# LAN side the VM should reach (inference box, MCP gateway); masqueraded below.
# Override with LAN_TARGET=... if the LAN ever moves.
# values.sh (gitignored) carries the real LAN target
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/../values.sh" ] && . "$(dirname "$0")/../values.sh"
LAN_TARGET="${LAN_TARGET:-${INFERENCE_IP:-}}"
LAN_IF="$(ip route get "$LAN_TARGET" 2>/dev/null | sed -n 's/.* dev \([^ ]*\) .*/\1/p' | head -1)"

# Accept VM traffic in all hooks at priority -1000 so it runs (and terminates
# with 'accept') BEFORE /etc/nftables.conf (empty forward policy drop) and
# Mullvad's tables (priority 0). output/input cover host<->VM; forward covers
# VM -> internet (routed by Mullvad's wg0-mullvad policy table => VPN'd).
nft delete table inet kali-vm 2>/dev/null || true
nft add table inet kali-vm
for h in output input forward; do
  nft add chain inet kali-vm "$h" "{ type filter hook $h priority -1000 ; policy accept ; }"
done
nft add rule inet kali-vm output  "oifname \"$BR\" accept"
nft add rule inet kali-vm input   "iifname \"$BR\" accept"
nft add rule inet kali-vm forward "iifname \"$BR\" accept"
nft add rule inet kali-vm forward "oifname \"$BR\" accept"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- CRITICAL: accept in one base chain does NOT short-circuit other base
# chains at the same hook. Forwarded VM traffic must be accepted by EVERY
# forward-hook chain with a drop policy:

# 1) /etc/nftables.conf 'inet filter' (policy drop) - only if actually loaded
#    (the conf itself now ships bridge accepts; this is a fallback)
if nft list table inet filter >/dev/null 2>&1; then
  nft list chain inet filter forward | grep -q 'br-' || {
    nft insert rule inet filter forward iifname "$BR" accept
    nft insert rule inet filter forward oifname "$BR" accept
  }
fi

# 2) Docker's 'ip filter' FORWARD chain (policy drop) - use its DOCKER-USER hook
iptables -C DOCKER-USER -i "$BR" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i "$BR" -j ACCEPT
iptables -C DOCKER-USER -o "$BR" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -o "$BR" -j ACCEPT

# Masquerade VM traffic into the Mullvad tunnel: the relay only accepts our
# assigned Mullvad inner IP as source; forwarded guest packets keep
# their own source (10.170.0.x) and get silently dropped otherwise.
nft delete table ip kali-nat 2>/dev/null || true
nft add table ip kali-nat
nft add chain ip kali-nat postrouting '{ type nat hook postrouting priority srcnat ; }'
nft add rule ip kali-nat postrouting ip saddr "$VMNET" oifname "wg0-mullvad" masquerade

# 3) Mullvad's 'inet mullvad' table also hooks forward; if its chain has a
#    drop policy, VM->LAN flows die there (VM->tunnel works because Mullvad
#    expects tunnelled traffic). Insert accepts if not already present.
#    NB: mullvad rebuilds its table on VPN state changes, wiping these:
#    re-run this script after mullvad reconnects (same as after nftables).
if nft list table inet mullvad >/dev/null 2>&1; then
  nft list chain inet mullvad forward 2>/dev/null | grep -q "$BR" || {
    nft insert rule inet mullvad forward iifname "$BR" accept
    nft insert rule inet mullvad forward oifname "$BR" accept
  }
fi

# VM -> LAN (inference box etc.): LAN hosts send replies to THEIR gateway,
# which has no route to 10.170.0.0/24, so masquerade VM sources to the
# host's LAN address. Without this the connection just times out.
if [ -n "$LAN_IF" ] && [ "$LAN_IF" != "$BR" ] && [ "$LAN_IF" != "wg0-mullvad" ]; then
  nft add rule ip kali-nat postrouting ip saddr "$VMNET" oifname "$LAN_IF" masquerade
  echo "VM -> LAN via $LAN_IF (target $LAN_TARGET): masqueraded"
else
  echo "NOTE: no LAN interface found for $LAN_TARGET; VM -> LAN not set up" >&2
fi

echo "done. firewall + forwarding + tunnel masquerade set for $BR"
