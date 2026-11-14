#!/bin/sh
# Validate LAN-only lighttpd socket selection and mandatory packet-filter guard.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/net/eth1" "$tmp/net/eth2" "$tmp/net/eth5" "$tmp/bin" "$tmp/web"
printf 'lfw:role=lan;name=LAN\n' >"$tmp/net/eth1/ifalias"
printf 'lfw:role=lan;name=IoT\n' >"$tmp/net/eth2/ifalias"
printf 'lfw:role=wan;name=WAN\n' >"$tmp/net/eth5/ifalias"
cat >"$tmp/bin/ip" <<'IP'
#!/bin/sh
case "$*" in
  *'dev eth1 scope global'*) echo '2: eth1 inet 10.0.1.199/24 brd 10.0.1.255 scope global eth1';;
  *'dev eth2 scope global'*) echo '3: eth2 inet 192.168.20.1/24 brd 192.168.20.255 scope global eth2';;
  *'dev eth5 scope global'*) echo '6: eth5 inet 203.0.113.12/24 brd 203.0.113.255 scope global eth5';;
esac
IP
chmod +x "$tmp/bin/ip"
echo 'server.port = 8080' >"$tmp/web/litefwm.conf"
export LITEFW_SYS_NET="$tmp/net" LFW_LIGHTTPD_CONF="$tmp/web/litefwm.conf"
export LFW_LIGHTTPD_BIND_CONF="$tmp/web/litefwm-bind.conf"
export LITEFW_PATH="$tmp/bin:/usr/sbin:/usr/bin:/sbin:/bin"
./bin/litefw-web-bind
grep -Fxq 'server.bind = "10.0.1.199"' "$LFW_LIGHTTPD_BIND_CONF"
grep -Fxq '$SERVER["socket"] == "192.168.20.1:8080" { }' "$LFW_LIGHTTPD_BIND_CONF"
! grep -Eq '203\.0\.113\.|0\.0\.0\.0' "$LFW_LIGHTTPD_BIND_CONF"
echo 'PASS: multiple LAN listeners and no WAN listener'
echo 'lfw:role=wan;name=OldLan' >"$tmp/net/eth1/ifalias"
echo 'lfw:role=wan;name=OldLan' >"$tmp/net/eth2/ifalias"
./bin/litefw-web-bind
grep -Fxq 'server.bind = "127.0.0.1"' "$LFW_LIGHTTPD_BIND_CONF"
! grep -q 'SERVER\["socket"\]' "$LFW_LIGHTTPD_BIND_CONF"
echo 'PASS: when no LAN exists web binds only loopback'
(
  . ./lib/fw.sh
  mgmt_port() { echo 8080; }
  lan_ifaces() { printf 'eth1\neth2\n'; }
  fw_gen_web >"$tmp/web/filter"
)
grep -Fxq 'iifname "eth1" tcp dport 8080 accept' "$tmp/web/filter"
grep -Fxq 'iifname "eth2" tcp dport 8080 accept' "$tmp/web/filter"
grep -Fxq 'tcp dport 8080 drop' "$tmp/web/filter"
! grep -q 'eth5' "$tmp/web/filter"
# The dedicated management port must be guarded before established packets.
awk '
 /printf.*tcp dport.*jump LFW_WEB/ {guard=NR}
 /echo.*ct state.*established/ {established=NR}
 END {exit !(guard && established && guard<established)}
' lib/fw.sh
echo 'PASS: nftables management guard emitted for LAN interfaces before established'
