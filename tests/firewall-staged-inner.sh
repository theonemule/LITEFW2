#!/bin/sh
set -eu
apk add -q --no-cache iptables jq iproute2 openssh >/dev/null
mkdir -p /etc/iptables /etc/litefwm
export LFW_LIB=/src/lib LFW_FW_CONFIRM_TIMEOUT=3
ctl() { /src/bin/lfwctl "$@"; }
ctl persist
ctl op rule.add '{"chain":"forward","action":"accept","proto":"tcp","ports":"443","description":"allow https"}' | jq -e '.ok' >/dev/null
ctl op rule.add '{"chain":"forward","action":"drop","proto":"tcp","ports":"80","description":"block http"}' | jq -e '.ok' >/dev/null
iptables -A LFW_FWD -i eth0 ! -s 10.0.1.0/24 -m comment --comment 'lfw:aabbccdd anti-spoof' -j DROP
iptables -t nat -A LFW_DNAT -i eth0 -p tcp -m tcp --dport 4444 -m comment --comment 'lfw:22222222 imported-forward' -j DNAT --to-destination 172.18.0.10:443
iptables-save >/etc/iptables/rules-save
ctl get firewall >/tmp/old.json
ctl get port-forwards >/tmp/nat.json
jq -n --slurpfile f /tmp/old.json --slurpfile n /tmp/nat.json \
  '{baseline:{rules:[$f[0].firewall.rules[]|{id,chain,raw,managed}],forwards:[$n[0].firewall.forwards[]|{id,raw,managed}]},rules:[$f[0].firewall.rules|to_entries[]|(.value+{origin:.key,changed:false})]|reverse,forwards:[$n[0].firewall.forwards|to_entries[]|(.value+{origin:.key,changed:false})]}' >/tmp/draft.json
jq '.baseline.rules=[]' /tmp/draft.json >/tmp/stale.json
jq '.rules[1].changed=true|.rules[1].proto="invalid"' /tmp/draft.json >/tmp/bad-rule.json
if ctl op firewall.batch "$(cat /tmp/bad-rule.json)" | jq -e '.ok' >/dev/null; then
  echo 'FAIL: invalid staged protocol accepted'; exit 1
fi
if ctl op firewall.batch "$(cat /tmp/stale.json)" | jq -e '.ok' >/dev/null; then
  echo 'FAIL: stale draft accepted'; exit 1
fi
before=$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)
ctl op firewall.batch "$(cat /tmp/draft.json)" >/tmp/result.json || { cat /tmp/result.json; nl -ba /tmp/litefw-fw-debug.ruleset; exit 1; }
cat /tmp/result.json
jq -e '.ok==true and .result.token!=null' /tmp/result.json >/dev/null
token=$(jq -r .result.token /tmp/result.json)
test "$before" = "$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)"
ctl op firewall.confirm "{\"token\":\"$token\"}" | jq -e '.ok' >/dev/null
test "$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)" != "$before"
sleep 4
ctl get firewall | jq -e '.firewall.rules[0].raw|contains("anti-spoof")' >/dev/null
ctl get port-forwards | jq -e '.firewall.forwards|length==1' >/dev/null
echo 'PASS: imported anti-spoof rule and NAT preserved; atomic apply and confirm persisted'
ctl get firewall >/tmp/old.json
jq -n --slurpfile f /tmp/old.json --slurpfile n /tmp/nat.json \
  '{baseline:{rules:[$f[0].firewall.rules[]|{id,chain,raw,managed}],forwards:[$n[0].firewall.forwards[]|{id,raw,managed}]},rules:[$f[0].firewall.rules|to_entries[]|(.value+{origin:.key,changed:false})]|reverse,forwards:[]}' >/tmp/rollback.json
saved=$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)
ctl op firewall.batch "$(cat /tmp/rollback.json)" | jq -e '.ok' >/dev/null
sleep 5
test "$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)" = "$saved"
ctl get firewall | jq -e '.firewall.rules[0].raw|contains("anti-spoof")' >/dev/null
ctl get port-forwards | jq -e '.firewall.forwards|length==1' >/dev/null
echo 'PASS: unconfirmed change auto-restored saved rules and NAT'
