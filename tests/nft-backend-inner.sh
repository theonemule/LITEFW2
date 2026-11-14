#!/bin/sh
# Native nftables integration; must run in a privileged disposable Alpine container.
set -eu
apk add -q --no-cache nftables jq iproute2 openssh >/dev/null
mkdir -p /tmp/litefw-run
export LFW_LIB=/src/lib LFW_RUN=/tmp/litefw-run
export LFW_FW_SAVE=/tmp/litefw-nftables.nft LFW_FW_CONFIRM_TIMEOUT=2
ctl() { /src/bin/lfwctl "$@"; }
ip link add lfw_wan type dummy
ip link add lfw_lan type dummy
ip link set lfw_wan up
ip link set lfw_lan up
ip link set dev lfw_wan alias 'lfw:role=wan;name=WAN'
ip link set dev lfw_lan alias 'lfw:role=lan;name=LAN'

# Preexisting native tables from another manager must survive all operations.
nft add table inet unrelated
ctl persist
nft list chain inet litefw INPUT | grep -q 'hook input.*policy drop'
nft list chain inet litefw INPUT | grep -q 'jump LFW_WEB'
nft list chain inet litefw LFW_WEB | grep -q 'lfw_lan'
! nft list chain inet litefw LFW_WEB | grep -q 'lfw_wan'
nft list chain inet litefw POSTROUTING | grep -q 'jump LFW_SNAT'
nft list chain inet litefw LFW_SNAT | grep -q 'lfw_wan.*masquerade'

rid=$(ctl op rule.add '{"chain":"forward","in":"lfw_lan","out":"lfw_wan","action":"drop","proto":"tcp","ports":"80,443","description":"blocked web"}' | jq -r '.result.id')
[ -n "$rid" ] && [ "$rid" != null ]
ctl get firewall | jq -e --arg id "$rid" '.firewall.rules[]|select(.id==$id and .managed==true and .action=="drop" and .ports=="80,443" and .proto=="tcp")' >/dev/null

fid=$(ctl op forward.add '{"in":"lfw_wan","proto":"both","port":"8443","to":"192.168.9.3","toPort":"443","description":"web"}' | jq -r '.result.id')
ctl get port-forwards | jq -e --arg id "$fid" '.firewall.forwards[]|select(.id==$id and .proto=="both" and .to=="192.168.9.3" and .toPort=="443")' >/dev/null
test "$(nft -a list chain inet litefw LFW_DNAT | grep -c "lfw:$fid")" -eq 2

# Explicit unmanaged native nft expressions survive an unchanged staged draft.
nft add rule inet litefw LFW_FWD iifname '"lfw_wan"' ip saddr '!=' 203.0.113.0/24 drop comment '"lfw:aabbccdd anti-spoof"'
ctl get firewall | jq -e '.firewall.rules[]|select(.id=="aabbccdd" and .managed==false)' >/dev/null

ctl get firewall >/tmp/fw-before.json
ctl get port-forwards >/tmp/fw-nat.json
jq -n --slurpfile f /tmp/fw-before.json --slurpfile n /tmp/fw-nat.json '
{baseline:{rules:[$f[0].firewall.rules[]|{id,chain,raw,managed}],forwards:[$n[0].firewall.forwards[]|{id,raw,managed}]},
rules:[$f[0].firewall.rules|to_entries[]|(.value+{origin:.key,changed:false})]|reverse,
forwards:[$n[0].firewall.forwards|to_entries[]|(.value+{origin:.key,changed:false})]}' >/tmp/draft.json
jq '.baseline.rules=[]' /tmp/draft.json >/tmp/stale.json
jq '.rules[1].changed=true | .rules[1].proto="not-a-protocol"' /tmp/draft.json >/tmp/bad.json
if ctl op firewall.batch "$(cat /tmp/bad.json)" | jq -e '.ok' >/dev/null; then
  echo 'FAIL: accepted invalid staged protocol' >&2; exit 1
fi
if ctl op firewall.batch "$(cat /tmp/stale.json)" | jq -e '.ok' >/dev/null; then
  echo 'FAIL: accepted stale draft' >&2; exit 1
fi
before=$(sha256sum "$LFW_FW_SAVE" | awk '{print $1}')
ctl op firewall.batch "$(cat /tmp/draft.json)" >/tmp/applied.json
jq -e '.ok and .result.token' /tmp/applied.json >/dev/null
[ "$(sha256sum "$LFW_FW_SAVE" | awk '{print $1}')" = "$before" ]
token=$(jq -r .result.token /tmp/applied.json)
ctl op firewall.confirm "{\"token\":\"$token\"}" | jq -e '.ok' >/dev/null
sleep 3
ctl get firewall | jq -e '.firewall.rules[0].id=="aabbccdd"' >/dev/null
nft list table inet unrelated >/dev/null

# An unconfirmed destructive change reverts the live table and saved boot file.
ctl get firewall >/tmp/fw-before.json
ctl get port-forwards >/tmp/fw-nat.json
jq -n --slurpfile f /tmp/fw-before.json --slurpfile n /tmp/fw-nat.json '
{baseline:{rules:[$f[0].firewall.rules[]|{id,chain,raw,managed}],forwards:[$n[0].firewall.forwards[]|{id,raw,managed}]},
rules:[],forwards:[]}' >/tmp/rollback.json
before=$(sha256sum "$LFW_FW_SAVE" | awk '{print $1}')
ctl op firewall.batch "$(cat /tmp/rollback.json)" | jq -e '.ok' >/dev/null
sleep 3
[ "$(sha256sum "$LFW_FW_SAVE" | awk '{print $1}')" = "$before" ]
ctl get firewall | jq -e '.firewall.rules|length==2' >/dev/null
ctl get port-forwards | jq -e '.firewall.forwards|length==1' >/dev/null
nft list table inet unrelated >/dev/null
# Confirm standalone edit/delete operations remain functional after staged apply.
ctl op rule.update "$(jq -nc --arg id "$rid" '{id:$id,chain:"forward",in:"lfw_lan",out:"lfw_wan",action:"accept",proto:"udp",ports:"5353",description:"new protocol"}')" | jq -e .ok >/dev/null
ctl get firewall | jq -e --arg id "$rid" '.firewall.rules[]|select(.id==$id and .proto=="udp" and .action=="accept" and .ports=="5353")' >/dev/null
ctl op forward.update "$(jq -nc --arg id "$fid" '{id:$id,in:"lfw_wan",proto:"tcp",port:"8444",to:"192.168.9.3",toPort:"443",description:"updated"}')" | jq -e .ok >/dev/null
ctl get port-forwards | jq -e --arg id "$fid" '.firewall.forwards[]|select(.id==$id and .proto=="tcp" and .port=="8444")' >/dev/null
ctl op forward.delete "$(jq -nc --arg id "$fid" '{id:$id}')" | jq -e .ok >/dev/null
ctl get port-forwards | jq -e '.firewall.forwards|length==0' >/dev/null
ctl op rule.delete "$(jq -nc --arg id "$rid" '{id:$id}')" | jq -e .ok >/dev/null
ctl get firewall | jq -e '.firewall.rules|length==1' >/dev/null
echo "PASS nftables: rule and NAT CRUD, API parsing, unmanaged rule retention, staged confirmation/rollback, foreign table safety"
