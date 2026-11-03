#!/bin/sh
set -eu
apk add -q --no-cache dnsmasq jq >/dev/null
install -d /tmp/litefw/dnsmasq
printf 'conf-dir=/tmp/litefw/dnsmasq,*.conf\n' >/tmp/litefw/dnsmasq.conf
export LFW_LIB=/src/lib LFW_DNSMASQ_CONF=/tmp/litefw/dnsmasq.conf LFW_DNSMASQ_DIR=/tmp/litefw/dnsmasq BODY=/tmp/litefw/body
. /src/lib/common.sh
. /src/lib/dhcp.sh
dnsmasq_apply() { dnsmasq_check || exit 1; }
cat >"$BODY" <<'EOF'
{"domain":"lan","upstream":["1.1.1.3","1.0.0.3"],"hosts":[{"name":"nas","ip":"10.0.1.7"}]}
EOF
op_dns_set
dnsmasq --test --conf-file="$LFW_DNSMASQ_CONF"
f=/tmp/litefw/dnsmasq/10-dns.conf
grep -Fxq no-resolv "$f"
grep -Fxq server=1.1.1.3 "$f"
grep -Fxq server=1.0.0.3 "$f"
! grep -Fq '1.1.1.1' "$f"
dns_read | jq -e '.upstream==["1.1.1.3","1.0.0.3"] and .hosts[0].ip=="10.0.1.7"' >/dev/null
echo 'PASS: family DNS profile uses only filtered dnsmasq upstreams'
cat >"$BODY" <<'EOF'
{"domain":"lan","upstream":["10.0.1.1"],"hosts":[]}
EOF
op_dns_set
dns_read | jq -e '.upstream==["10.0.1.1"]' >/dev/null
grep -Fxq server=10.0.1.1 "$f"
echo 'PASS: custom upstream remains supported'
cat >"$BODY" <<'EOF'
{"domain":"lan","upstream":[],"hosts":[]}
EOF
op_dns_set
dns_read | jq -e '.upstream==[]' >/dev/null
! grep -q '^no-resolv' "$f"
! grep -q '^server=' "$f"
test -z "$(find /tmp/litefw/dnsmasq -name '30-dhcp-*' -print)"
echo 'PASS: automatic WAN/system DNS restored; no DHCP scope created'
