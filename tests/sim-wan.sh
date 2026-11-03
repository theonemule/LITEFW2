#!/bin/sh
# Execute only within the disposable privileged Alpine behavior-test container.
set -eu
cd /workspace
source_root=/workspace
state=$(mktemp -d)
trap 'rm -rf "$state"; rm -f /run/litefwm/multiwan-original-route' EXIT HUP INT TERM
mkdir -p "$state/conf"
export LFW_MODULE_CONFIG_DIR="$state/conf"
checker="$source_root/modules/shared/multiwan-check.sh"
test -x "$checker"

echo 'CASE wan/disabled-is-noop'
original=$(ip -4 route show default | head -1)
test -n "$original" || { echo 'A disposable Docker default route is required'; exit 1; }
jq -n '{enabled:false,uplinks:[{interface:"lfw_w1",gateway:"10.254.1.1",priority:10},{interface:"lfw_w2",gateway:"10.254.2.1",priority:20}]}' > "$LFW_MODULE_CONFIG_DIR/multiwan.json"
"$checker"
test "$(ip -4 route show default | head -1)" = "$original"
test ! -f /run/litefwm/multiwan-original-route

echo 'CASE wan/two-real-gateway-links'
for number in 1 2; do
  ip link add "lfw_w$number" type veth peer name "lfw_g$number"
  ip addr add "10.254.$number.2/30" dev "lfw_w$number"
  ip netns add "lfw_gateway$number"
  ip link set "lfw_g$number" netns "lfw_gateway$number"
  ip netns exec "lfw_gateway$number" ip addr add "10.254.$number.1/30" dev "lfw_g$number"
  ip link set "lfw_w$number" up
  ip netns exec "lfw_gateway$number" ip link set "lfw_g$number" up
  ping -n -c 1 -W 2 -I "lfw_w$number" "10.254.$number.1" >/dev/null
done
jq '.enabled=true' "$LFW_MODULE_CONFIG_DIR/multiwan.json" >"$state/on"
mv "$state/on" "$LFW_MODULE_CONFIG_DIR/multiwan.json"
"$checker"
ip -4 route show default | grep -Fq 'via 10.254.1.1 dev lfw_w1'
test "$(cat /run/litefwm/multiwan-original-route)" = "$original"
echo 'PASS WAN prefers the healthy first gateway'

echo 'CASE wan/failure-detected-and-failover'
# Disable *peer* rather than the interface: the old route must not be silently
# deleted by the kernel before the checker's recovery logic runs.
ip netns exec lfw_gateway1 ip link set lfw_g1 down
if ping -n -c 1 -W 1 -I lfw_w1 10.254.1.1 >/dev/null 2>&1; then
  echo 'FAIL test fixture: failed gateway remains reachable' >&2; exit 1
fi
"$checker"
ip -4 route show default | grep -Fq 'via 10.254.2.1 dev lfw_w2'
test "$(cat /run/litefwm/multiwan-original-route)" = "$original"
echo 'PASS primary failure selects healthy backup without losing original route'

echo 'CASE wan/all-gateways-down-preserve-route'
ip netns exec lfw_gateway2 ip link set lfw_g2 down
before=$(ip -4 route show default | head -1)
if "$checker"; then
  echo 'FAIL checker returned success with no reachable gateways' >&2; exit 1
fi
test "$(ip -4 route show default | head -1)" = "$before"
echo 'PASS no reachable gateway raises an error without routing to dead gateway'

echo 'CASE wan/recovery-failback'
ip netns exec lfw_gateway1 ip link set lfw_g1 up
ping -n -c 1 -W 2 -I lfw_w1 10.254.1.1 >/dev/null
"$checker"
ip -4 route show default | grep -Fq 'via 10.254.1.1 dev lfw_w1'
echo 'PASS preferred gateway recovery triggers failback'

echo 'CASE wan/backup-nat'
LFW_LIB="$source_root/lib"
export LFW_LIB
. "$LFW_LIB/common.sh"
. "$LFW_LIB/modules.sh"
out=$(module_firewall_snat_rules lfw_w1)
printf '%s\n' "$out" | grep -Fq -- '-A LFW_SNAT -o lfw_w2 -j MASQUERADE'
if printf '%s\n' "$out" | grep -Fq -- '-A LFW_SNAT -o lfw_w1 -j MASQUERADE'; then
  echo 'FAIL duplicate primary WAN SNAT rule' >&2; exit 1
fi
jq '.enabled=false' "$LFW_MODULE_CONFIG_DIR/multiwan.json" >"$state/off"
mv "$state/off" "$LFW_MODULE_CONFIG_DIR/multiwan.json"
test -z "$(module_firewall_snat_rules lfw_w1)"
echo 'PASS backup SNAT is conditional on active multi-WAN mode'

echo 'CASE wan/restore-original'
ip -4 route replace $original
test "$(ip -4 route show default | head -1)" = "$original"
echo 'PASS original route is restorable'
