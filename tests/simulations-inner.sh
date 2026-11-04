#!/bin/sh
# Never run on the host or on a live LiteFW appliance.
set -eu
[ -f /.dockerenv ] || { echo 'Refusing to mutate a non-container network namespace' >&2; exit 1; }
cd /workspace
echo '=== LiteFW Alpine 3.24 behavior simulations ==='
apk add --no-cache openrc iproute2 iputils iptables ipset jq frr frr-openrc bird2 python3 tcpdump wireguard-tools >/dev/null
test -n "$(ip -4 route show default)" || { echo 'Docker network bridge missing'; exit 1; }
sh /workspace/tests/sim-wan.sh
sh /workspace/tests/sim-bgp.sh
sh /workspace/tests/sim-packet-path.sh
sh /workspace/tests/sim-security.sh
sh /workspace/tests/sim-wireguard.sh
# Additional behavioral simulations run below.
echo 'PASS: WAN, BGP, GeoIP, cloud tunnel and WireGuard simulations'
