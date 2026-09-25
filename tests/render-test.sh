#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
export LITEFWM_ETC="$TMP/etc"
export LITEFWM_CONFIG="$ROOT/tests/fixtures/full.json"
export LITEFWM_STATE="$TMP/state"
export LITEFWM_RUN="$TMP/run"
export LITEFWM_LOG="$TMP/log"
export LITEFWM_GENERATED="$TMP/state/generated"

"$ROOT/bin/configctl" validate "$LITEFWM_CONFIG" >/dev/null
net=$("$ROOT/bin/netctl" render)
fw=$("$ROOT/bin/firewallctl" render)
dhcp=$("$ROOT/bin/dhcpctl" render)
web=$("$ROOT/bin/webctl" render)

grep -Fq "ip route replace default via '203.0.113.1' dev 'eth0'" "$net"
grep -Fq "ip link add name 'br0' type bridge" "$net"
grep -Fq "ip link set dev 'br0' type bridge vlan_filtering '1'" "$net"
grep -Fq "ip link set dev 'eth1' master 'br0'" "$net"
grep -Fq "ip link set dev 'eth2' master 'br0'" "$net"
grep -Fq "ip link add link 'br0' name 'br0.20' type vlan id '20'" "$net"
grep -Fq "bridge vlan add dev 'br0' vid '20' self" "$net"
grep -Fq "bridge vlan add dev 'eth1' vid '20'" "$net"
grep -Fq "bridge vlan add dev 'eth2' vid '20'" "$net"

grep -Fq ':INPUT DROP [0:0]' "$fw"
grep -Fq ':FORWARD DROP [0:0]' "$fw"
grep -Fq -- "-A INPUT -p tcp --dport 22 -j ACCEPT" "$fw"
grep -Fq -- "-A INPUT -i br0 -p tcp --dport 5187 -j ACCEPT" "$fw"
grep -Fq -- "-A POSTROUTING -o eth0 -s 192.168.10.0/24 -j MASQUERADE" "$fw"
grep -Fq -- "-A PREROUTING -i eth0 -p tcp --dport 443 -j DNAT --to-destination 192.168.10.50:443" "$fw"

grep -Fq "dhcp-range=set:lan,192.168.10.100,192.168.10.200,12h" "$dhcp"
grep -Fq "dhcp-host=02:00:00:00:00:50,192.168.10.50,server" "$dhcp"
grep -Fq "server.port = 5187" "$web"

echo "render-test: PASS"
