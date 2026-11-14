#!/bin/sh
# Unified host/WAN/segment rule API and precedence through native nftables.
set -eu
apk add -q --no-cache nftables iproute2 jq openssh >/dev/null
mkdir -p /tmp/lfw-unified
export LFW_LIB=/src/lib LFW_RUN=/tmp/lfw-unified LFW_FW_SAVE=/tmp/lfw-unified/boot.nft
export LFW_FW_CONFIRM_TIMEOUT=3
ctl() { /src/bin/lfwctl "$@"; }
ip link add lfw_wan type dummy; ip link set lfw_wan up
ip link add lfw_lan type dummy; ip link set lfw_lan up
ip link set dev lfw_wan alias 'lfw:role=wan;name=WAN'
ip link set dev lfw_lan alias 'lfw:role=lan;name=Office'
ctl persist
r1=$(ctl op rule.add '{
  "source":{"scope":"interface","interface":"lfw_lan","address":"192.0.2.4-192.0.2.20","ports":"1024-65535"},
  "destination":{"scope":"wan","address":"1.1.1.1,8.8.8.8","ports":"443"},
  "action":"drop","proto":"tcp","description":"Office DNS block"
}' | jq -er '.result.id')
r2=$(ctl op rule.add '{
  "source":{"scope":"wan","address":"198.51.100.0/24","ports":""},
  "destination":{"scope":"host","address":"","ports":""},
  "action":"reject","proto":"icmp","description":"Block WAN ping"
}' | jq -er '.result.id')
r3=$(ctl op rule.add '{
  "source":{"scope":"host","address":"","ports":""},
  "destination":{"scope":"wan","address":"","ports":"53"},
  "action":"drop","proto":"udp","description":"Block host DNS"
}' | jq -er '.result.id')
ctl get firewall >/tmp/lfw-unified/state.json
jq -e --arg a "$r1" --arg b "$r2" --arg c "$r3" '
  .firewall.rules | length==3 and
  (.[0].id==$a and .[0].chain=="forward" and .[0].managed and .[0].src=="192.0.2.4-192.0.2.20" and .[0].srcPorts=="1024-65535" and .[0].destination.scope=="wan" and .[0].destination.ports=="443") and
  (.[1].id==$b and .[1].chain=="input" and .[1].managed==true and .[1].destination.scope=="host") and
  (.[2].id==$c and .[2].chain=="output" and .[2].source.scope=="host")
' /tmp/lfw-unified/state.json >/dev/null
nft list chain inet litefw LFW_OUT | grep -q "lfw:$r3"
nft list chain inet litefw OUTPUT | grep -q 'jump LFW_OUT'
nft list chain inet litefw LFW_IN | grep -q "lfw:$r2"
nft list chain inet litefw LFW_FWD | grep -q "lfw:$r1"
# Re-order across the three hook types and ensure it persists in native kernel state.
ctl get port-forwards >/tmp/lfw-unified/forwards.json
jq -n --slurpfile x /tmp/lfw-unified/state.json --slurpfile n /tmp/lfw-unified/forwards.json '{
  baseline:{rules:[$x[0].firewall.rules[]|{id,chain,raw,managed}],forwards:[$n[0].firewall.forwards[]|{id,raw,managed}]},
  rules:[$x[0].firewall.rules | to_entries[] | (.value+{origin:.key,changed:false})] | reverse,
  forwards:[]
}' >/tmp/lfw-unified/draft.json
ctl op firewall.batch "$(cat /tmp/lfw-unified/draft.json)" >/tmp/lfw-unified/change.json
jq -e '.ok==true and .result.token!=null' /tmp/lfw-unified/change.json >/dev/null
token=$(jq -r .result.token /tmp/lfw-unified/change.json)
ctl op firewall.confirm "{\"token\":\"$token\"}" | jq -e .ok >/dev/null
ctl get firewall | jq -e --arg a "$r1" --arg b "$r2" --arg c "$r3" '
  [.firewall.rules[].id]==[$c,$b,$a]' >/dev/null
nft -c -f "$LFW_FW_SAVE"
# Host-to-host must not be confused with any interface.
if ctl op rule.add '{"source":{"scope":"host"},"destination":{"scope":"host"},"action":"accept","proto":"any"}' | jq -e .ok >/dev/null; then
  echo "FAIL: host-to-host policy accepted" >&2; exit 1
fi
# Invalid addresses and injected nftables expressions must be refused.
if ctl op rule.add '{"source":{"scope":"any","address":"192.0.2.1; drop"},"destination":{"scope":"wan"},"action":"accept","proto":"tcp","destinationPorts":"443"}' | jq -e .ok >/dev/null; then
  echo "FAIL: unsafe address input accepted" >&2; exit 1
fi
echo 'PASS unified source/destination API, range/lists/source ports, host input/output, global display order and validation'