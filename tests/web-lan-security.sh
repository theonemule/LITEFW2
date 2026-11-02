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
grep -Fxq -- '-A LFW_WEB -i eth1 -p tcp -m tcp --dport 8080 -j ACCEPT' "$tmp/web/filter"
grep -Fxq -- '-A LFW_WEB -i eth2 -p tcp -m tcp --dport 8080 -j ACCEPT' "$tmp/web/filter"
grep -Fxq -- '-A LFW_WEB -p tcp -m tcp --dport 8080 -j DROP' "$tmp/web/filter"
! grep -q -- 'eth5' "$tmp/web/filter"
echo 'PASS: firewall web guard allows LAN and denies other interfaces'
# Build the actual iptables-restore transaction, with fake kernel writers.
cat >"$tmp/bin/iptables-restore" <<'MOCK'
#!/bin/sh
cat >"$FW_RESTORE_FILE"
MOCK
cat >"$tmp/bin/iptables-save" <<'MOCK'
#!/bin/sh
cat "$FW_RESTORE_FILE"
MOCK
chmod +x "$tmp/bin/iptables-restore" "$tmp/bin/iptables-save"
mkdir -p "$tmp/chains"
: >"$tmp/chains/LFW_IN"; : >"$tmp/chains/LFW_FWD"
: >"$tmp/chains/LFW_MGMT"; : >"$tmp/chains/LFW_DNAT"
echo '-A LFW_IN -i eth5 -p tcp --dport 8080 -j ACCEPT' >"$tmp/chains/LFW_IN"
(
  . ./lib/fw.sh
  mgmt_port() { echo 8080; }
  ssh_port() { echo 22; }
  ssh_enabled() { return 1; }
  lan_ifaces() { echo eth1; }
  wan_iface() { echo eth5; }
  dhcpd_exists() { return 1; }
  PATH="$tmp/bin:$PATH"
  export PATH FW_RESTORE_FILE="$tmp/restored"
  LFW_FW_SAVE="$tmp/saved"
  FWT="$tmp/chains"
  fw_commit any
)
grep -Fxq -- '-A INPUT -p tcp -m tcp --dport 8080 -j LFW_WEB' "$tmp/restored"
grep -Fxq -- '-A LFW_WEB -i eth1 -p tcp -m tcp --dport 8080 -j ACCEPT' "$tmp/restored"
grep -Fxq -- '-A LFW_WEB -p tcp -m tcp --dport 8080 -j DROP' "$tmp/restored"
awk '
 /-A INPUT -p tcp -m tcp --dport 8080 -j LFW_WEB/ {guard=NR}
 /-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT/ {established=NR}
 END {exit !(guard && established && guard<established)}
' "$tmp/restored"
echo 'PASS: real firewall transaction guards the web port before established traffic'