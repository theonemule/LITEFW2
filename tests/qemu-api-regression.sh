#!/bin/bash
# Full resource-API regression against the running tests/qemu-lab.sh appliance.
# Mutations are verified against native Linux/service behavior and cleaned up.
set -u -o pipefail

LAB=${LFW_QEMU_LAB_DIR:-/tmp/litefwm2-qemu-lab}
FW=172.30.50.2
LAN=172.30.60.1
APP1=172.30.60.11
APP2=172.30.60.12
OUTSIDE=172.30.50.100
OUT_NS=lfw2out
VM_PASS=${LFW_QEMU_PASSWORD:-pwd1234}
[ -r "$LAB/env" ] || { echo "QEMU lab is not installed: $LAB/env missing" >&2; exit 2; }
ORIG_AUTH=$(sed -n 's/^API_PASSWORD=//p' "$LAB/env")
AUTH=$ORIG_AUTH
exec 8>"$LAB/regression.lock"
flock -n 8 || { echo "another QEMU API regression is already running" >&2; exit 2; }
PASS=0
FAIL=0
TMP_RULES=""
TMP_FORWARD=""
REGV=eth1.4090
REGB=brreg
ORIG_HOST=""
ORIG_DNS=""

say(){ printf '\n== %s ==\n' "$*"; }
ok(){ printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
ssh_fw(){
  sshpass -p "$VM_PASS" ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"$FW" "$@"
}
ssh_app2(){
  sshpass -p "$VM_PASS" ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"$APP2" "$@"
}
api(){
  local p=$1; shift || true
  curl -fsS -u "admin:$AUTH" "$@" "http://$FW/api/$p"
}
post(){
  local p=$1 body=$2
  api "$p" -H 'X-LiteFWM: 1' -H 'Content-Type: application/json' -d "$body"
}
LAST_JSON='{}'
post_ok(){
  local d=$1 p=$2 body=$3 j
  if j=$(post "$p" "$body" 2>/dev/null) && printf '%s' "$j" | jq -e '.ok == true' >/dev/null 2>&1; then
    LAST_JSON=$j
    ok "$d" >&2
    printf '%s\n' "$j"
    return 0
  fi
  LAST_JSON=${j:-'{}'}
  bad "$d" >&2
  printf '%s\n' "$LAST_JSON" >&2
  return 1
}
jq_check(){
  local d=$1 p=$2 j
  shift 2
  if j=$(api "$p" 2>/dev/null) && printf '%s' "$j" | jq -e "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
outside_fetch(){
  local port=$1 pattern=$2
  sudo ip netns exec "$OUT_NS" busybox wget -q -T 4 -O - "http://$FW:$port/" 2>/dev/null | grep -q "$pattern"
}
outside_ping(){ sudo ip netns exec "$OUT_NS" ping -c1 -W2 "$FW" >/dev/null 2>&1; }

cleanup(){
  set +e
  AUTH=$ORIG_AUTH
  # If the password test was interrupted while the temporary password was active, restore it.
  if [ "$(curl -s -o /dev/null -w '%{http_code}' -u 'admin:RegressionPass123!' "http://$FW/api/identity")" = 200 ]; then
    AUTH='RegressionPass123!'
    post system/password "$(jq -nc --arg p "$ORIG_AUTH" '{user:"admin",password:$p}')" >/dev/null 2>&1
    AUTH=$ORIG_AUTH
  fi
  # Remove temporary managed firewall objects by description.
  api firewall 2>/dev/null | jq -r '.firewall.rules[] | select(.description|startswith("regression ")) | .id' | while read -r id; do
    [ -n "$id" ] && post firewall/rules/delete "$(jq -nc --arg id "$id" '{id:$id}')" >/dev/null 2>&1
  done
  api port-forwards 2>/dev/null | jq -r '.firewall.forwards[] | select(.description|startswith("regression ")) | .id' | while read -r id; do
    [ -n "$id" ] && post port-forwards/delete "$(jq -nc --arg id "$id" '{id:$id}')" >/dev/null 2>&1
  done
  post dhcp/reservations/delete '{"mac":"02:00:00:00:00:99"}' >/dev/null 2>&1
  post dhcp/server/set '{"interface":"eth1","enabled":false}' >/dev/null 2>&1
  if [ -n "$ORIG_DNS" ]; then post dns/set "$(printf '%s' "$ORIG_DNS" | jq -c '.dns')" >/dev/null 2>&1; fi
  if [ -n "$ORIG_HOST" ]; then post system/set "$(jq -nc --arg h "$ORIG_HOST" '{hostname:$h}')" >/dev/null 2>&1; fi
  post system/management '{"port":80,"sshEnabled":true,"sshPort":22,"access":"any"}' >/dev/null 2>&1
  post system/logging '{"remoteEnabled":false,"server":"","port":514,"localEnabled":true}' >/dev/null 2>&1
  post interfaces/bridge/delmember "$(jq -nc --arg b "$REGB" --arg m "$REGV" '{bridge:$b,member:$m}')" >/dev/null 2>&1
  post interfaces/bridge/delete "$(jq -nc --arg n "$REGB" '{name:$n}')" >/dev/null 2>&1
  post interfaces/vlan/delete "$(jq -nc --arg n "$REGV" '{name:$n}')" >/dev/null 2>&1
  for m in bind openvpn ddns; do post "modules/$m/remove" '{}' >/dev/null 2>&1; done
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

if [ "${1:-}" = cleanup ]; then
  ORIG_HOST=fw
  ORIG_DNS='{"dns":{"domain":"lan","upstream":[],"hosts":[]}}'
  cleanup
  trap - EXIT INT TERM
  exit 0
fi

say "read APIs and live-source consistency"
ORIG_HOST=$(api identity | jq -r '.hostname')
ORIG_DNS=$(api dns)
for r in identity overview interfaces segments firewall port-forwards dhcp dns modules system modules/bind modules/openvpn modules/ddns; do
  if api "$r" | jq -e . >/dev/null 2>&1; then ok "GET /api/$r returns JSON"; else bad "GET /api/$r returns JSON"; fi
done
jq_check "identity matches native hostname" identity --arg h "$(ssh_fw hostname)" '.hostname == $h'
jq_check "interfaces expose both physical NICs" interfaces '[.interfaces[]|select(.kind=="physical")]|length == 2'
jq_check "segment API reads live WAN/LAN roles" segments '([.interfaces[]|select(.name=="eth0")|.role][0]=="wan") and ([.interfaces[]|select(.name=="eth1")|.role][0]=="lan")'
check "overview firewall rule really permits LAN egress" ssh_app2 "wget -q -T 4 -O - http://$OUTSIDE:8088/ | grep -q outside"
check "baseline DNAT really reaches app1" outside_fetch 8080 hello-from-app1

say "interface, bridge, VLAN, and segment mutation APIs"
j=$(post_ok "POST VLAN create" interfaces/vlan/create '{"parent":"eth1","vid":4090,"name":"eth1.4090"}') || true
check "VLAN exists in kernel" ssh_fw "ip -d link show dev $REGV | grep -q 'vlan.*id 4090'"
post_ok "POST interface MTU set" interfaces/iface/set "$(jq -nc --arg n "$REGV" '{name:$n,mtu:1400}')" >/dev/null || true
check "MTU changed in kernel" ssh_fw "grep -qx 1400 /sys/class/net/$REGV/mtu"
post_ok "POST segment set" segments/set "$(jq -nc --arg i "$REGV" '{interface:$i,label:"REGTEST",role:"lan",mode:"static",addresses:["192.0.2.1/24"]}')" >/dev/null || true
check "segment address exists in kernel" ssh_fw "ip -4 addr show dev $REGV | grep -q '192.0.2.1/24'"
jq_check "segment read reflects live VLAN address" segments '.interfaces[]|select(.name=="eth1.4090")|(.role=="lan" and .label=="REGTEST" and (.addresses|index("192.0.2.1/24")!=null))'
post_ok "clear test segment before bridge membership" segments/set "$(jq -nc --arg i "$REGV" '{interface:$i,label:"",role:"none",mode:"none",addresses:[]}')" >/dev/null || true
post_ok "POST bridge create" interfaces/bridge/create "$(jq -nc --arg n "$REGB" '{name:$n,vlanFiltering:false,members:[]}')" >/dev/null || true
check "bridge exists in kernel" ssh_fw "ip -d link show dev $REGB | grep -q bridge"
post_ok "POST bridge set VLAN filtering" interfaces/bridge/set "$(jq -nc --arg n "$REGB" '{name:$n,vlanFiltering:true}')" >/dev/null || true
check "bridge VLAN filtering changed in kernel" ssh_fw "ip -d -j link show dev $REGB | jq -e '.[0].linkinfo.info_data.vlan_filtering == 1'"
post_ok "POST bridge add member" interfaces/bridge/addmember "$(jq -nc --arg b "$REGB" --arg m "$REGV" '{bridge:$b,member:$m}')" >/dev/null || true
check "bridge member is native kernel state" ssh_fw "readlink /sys/class/net/$REGV/master | grep -q '/$REGB$'"
post_ok "POST bridge port VLANs" interfaces/bridge/portvlans "$(jq -nc --arg b "$REGB" --arg p "$REGV" '{bridge:$b,port:$p,pvid:100,tagged:[200]}')" >/dev/null || true
check "PVID/tagged VLANs exist in bridge table" ssh_fw "bridge vlan show dev $REGV | grep -q '100 PVID Egress Untagged' && bridge vlan show dev $REGV | grep -Eq '(^|[[:space:]])200([[:space:]]|$)'"
post_ok "POST bridge delete member" interfaces/bridge/delmember "$(jq -nc --arg b "$REGB" --arg m "$REGV" '{bridge:$b,member:$m}')" >/dev/null || true
check "bridge member removed in kernel" ssh_fw "test ! -L /sys/class/net/$REGV/master"
post_ok "POST bridge delete" interfaces/bridge/delete "$(jq -nc --arg n "$REGB" '{name:$n}')" >/dev/null || true
check "bridge deleted in kernel" ssh_fw "! ip link show dev $REGB >/dev/null 2>&1"
post_ok "POST VLAN delete" interfaces/vlan/delete "$(jq -nc --arg n "$REGV" '{name:$n}')" >/dev/null || true
check "VLAN deleted in kernel" ssh_fw "! ip link show dev $REGV >/dev/null 2>&1"

say "firewall rule APIs with real WAN traffic"
j=$(post_ok "POST firewall rule add" firewall/rules/add '{"chain":"input","action":"accept","in":"eth0","proto":"icmp","description":"regression ping allow","position":0}') || true
RID1=$(printf '%s' "$j" | jq -r '.result.id // empty')
[ -n "$RID1" ] && TMP_RULES="$RID1"
check "added INPUT rule permits WAN ping" outside_ping
j=$(post_ok "POST second firewall rule add" firewall/rules/add '{"chain":"input","action":"reject","in":"eth0","proto":"tcp","ports":"65534","description":"regression order B"}') || true
RID2=$(printf '%s' "$j" | jq -r '.result.id // empty')
post_ok "POST firewall rule update" firewall/rules/update "$(jq -nc --arg id "$RID2" '{id:$id,chain:"input",action:"reject",in:"eth0",proto:"tcp",ports:"65533",description:"regression order B updated"}')" >/dev/null || true
jq_check "updated firewall rule is live in iptables-backed read" firewall --arg id "$RID2" '.firewall.rules[]|select(.id==$id)|(.ports=="65533" and .description=="regression order B updated")'
post_ok "POST firewall rule move" firewall/rules/move "$(jq -nc --arg id "$RID2" '{id:$id,position:0}')" >/dev/null || true
jq_check "rule move changes evaluation order" firewall --arg id "$RID2" '[.firewall.rules[]|select(.chain=="input")][0].id == $id'
post_ok "POST second firewall rule delete" firewall/rules/delete "$(jq -nc --arg id "$RID2" '{id:$id}')" >/dev/null || true
post_ok "POST firewall rule update to reject ping" firewall/rules/update "$(jq -nc --arg id "$RID1" '{id:$id,chain:"input",action:"reject",in:"eth0",proto:"icmp",description:"regression ping reject"}')" >/dev/null || true
if outside_ping; then bad "updated reject rule blocks WAN ping"; else ok "updated reject rule blocks WAN ping"; fi
post_ok "POST firewall rule delete" firewall/rules/delete "$(jq -nc --arg id "$RID1" '{id:$id}')" >/dev/null || true
if outside_ping; then bad "default policy blocks WAN ping after cleanup"; else ok "default policy blocks WAN ping after cleanup"; fi

say "port-forward APIs with real HTTP backends"
j=$(post_ok "POST port forward add" port-forwards/add '{"proto":"tcp","port":"18081","to":"172.30.60.11","toPort":"80","description":"regression forward"}') || true
FID=$(printf '%s' "$j" | jq -r '.result.id // empty')
check "new DNAT reaches app1" outside_fetch 18081 hello-from-app1
post_ok "POST port forward update" port-forwards/update "$(jq -nc --arg id "$FID" '{id:$id,proto:"tcp",port:"18081",to:"172.30.60.12",toPort:"80",description:"regression forward updated"}')" >/dev/null || true
check "updated DNAT reaches app2" outside_fetch 18081 hello-from-app2
post_ok "POST port forward delete" port-forwards/delete "$(jq -nc --arg id "$FID" '{id:$id}')" >/dev/null || true
if outside_fetch 18081 hello >/dev/null 2>&1; then bad "deleted DNAT closes WAN port"; else ok "deleted DNAT closes WAN port"; fi

say "DHCP, reservations, DNS, and diagnostics APIs"
post_ok "POST DHCP server set enabled" dhcp/server/set '{"interface":"eth1","enabled":true,"start":"172.30.60.100","end":"172.30.60.120","leaseTime":"1h","router":"172.30.60.1","dns":["172.30.60.1"],"domain":"reg.lan","ntp":[]}' >/dev/null || true
jq_check "DHCP API reads enabled native server" dhcp '.interfaces[]|select(.name=="eth1")|.dhcpServer.enabled == true'
check "dnsmasq native config contains DHCP range" ssh_fw "grep -Rqs '172.30.60.100,172.30.60.120' /etc/dnsmasq.d"
check "dnsmasq is running after DHCP change" ssh_fw "rc-service dnsmasq status"
post_ok "POST reservation add" dhcp/reservations/add '{"mac":"02:00:00:00:00:99","ip":"172.30.60.99","hostname":"regclient"}' >/dev/null || true
jq_check "reservation API reads native hosts file" dhcp '.dhcp.reservations[]|select(.mac=="02:00:00:00:00:99")|(.ip=="172.30.60.99" and .hostname=="regclient")'
check "reservation exists in dnsmasq hosts file" ssh_fw "grep -Rqs '02:00:00:00:00:99,172.30.60.99,regclient' /etc/dnsmasq.hosts.d"
post_ok "POST DNS set" dns/set '{"domain":"reg.lan","upstream":["1.1.1.1"],"hosts":[{"name":"api-regression","ip":"172.30.60.11"}]}' >/dev/null || true
jq_check "DNS read reflects native config" dns '.dns.domain=="reg.lan" and (.dns.upstream|index("1.1.1.1")!=null) and ([.dns.hosts[]|select(.name=="api-regression" and .ip=="172.30.60.11")]|length==1)'
check "LAN client resolves local DNS record through firewall" ssh_app2 "nslookup api-regression.reg.lan $LAN | grep -q '172.30.60.11'"
j=$(post_ok "POST diagnostic ping" system/diagnostics/ping "$(jq -nc --arg h "$OUTSIDE" '{host:$h}')") || true
if printf '%s' "$j" | jq -e '.result.output|test("3 packets transmitted")' >/dev/null 2>&1; then ok "diagnostic ping returns native ping output"; else bad "diagnostic ping returns native ping output"; fi
j=$(post_ok "POST diagnostic lookup" system/diagnostics/lookup '{"host":"api-regression.reg.lan"}') || true
if printf '%s' "$j" | jq -e '.result.output|contains("172.30.60.11")' >/dev/null 2>&1; then ok "diagnostic lookup uses local DNS"; else bad "diagnostic lookup uses local DNS"; fi
post_ok "POST reservation delete" dhcp/reservations/delete '{"mac":"02:00:00:00:00:99"}' >/dev/null || true
jq_check "reservation removed from native state" dhcp '[.dhcp.reservations[]|select(.mac=="02:00:00:00:00:99")]|length == 0'
post_ok "POST DHCP server disable" dhcp/server/set '{"interface":"eth1","enabled":false}' >/dev/null || true
jq_check "DHCP server disable reflected live" dhcp '.interfaces[]|select(.name=="eth1")|.dhcpServer.enabled == false'
post_ok "restore original DNS config" dns/set "$(printf '%s' "$ORIG_DNS" | jq -c '.dns')" >/dev/null || true

say "system, management, and credential APIs"
post_ok "POST system hostname set" system/set '{"hostname":"fw-regression"}' >/dev/null || true
check "native hostname changed" ssh_fw "hostname | grep -qx fw-regression"
jq_check "system API reads changed hostname" system '.system.hostname=="fw-regression"'
post_ok "restore system hostname" system/set "$(jq -nc --arg h "$ORIG_HOST" '{hostname:$h}')" >/dev/null || true
post_ok "POST management access scoped to both NICs" system/management '{"port":80,"sshEnabled":true,"sshPort":22,"access":["eth0","eth1"]}' >/dev/null || true
jq_check "management API reads scoped interfaces" system '.system.management.access == ["eth0","eth1"]'
check "web server still answers after management change" curl -fsS -u "admin:$AUTH" "http://$FW/api/identity"
check "SSH still answers after management change" ssh_fw "true"
post_ok "restore management access any" system/management '{"port":80,"sshEnabled":true,"sshPort":22,"access":"any"}' >/dev/null || true
post_ok "POST remote syslog settings" system/logging '{"remoteEnabled":true,"server":"172.30.50.100","port":5514,"localEnabled":true}' >/dev/null || true
jq_check "system API reads native remote syslog settings" system '.system.logging.remoteEnabled == true and .system.logging.server == "172.30.50.100" and .system.logging.port == 5514 and .system.logging.localEnabled == true'
check "native syslogd options contain remote collector and local logging" ssh_fw "grep -q -- '-R 172.30.50.100:5514' /etc/conf.d/syslog && grep -q -- '-L' /etc/conf.d/syslog"
post_ok "restore local-only syslog" system/logging '{"remoteEnabled":false,"server":"","port":514,"localEnabled":true}' >/dev/null || true
jq_check "system API reports local-only syslog after restore" system '.system.logging.remoteEnabled == false and .system.logging.localEnabled == true'
TEMP_PASS='RegressionPass123!'
j=$(post_ok "POST admin password change" system/password "$(jq -nc --arg p "$TEMP_PASS" '{user:"admin",password:$p}')") || true
old_status=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$ORIG_AUTH" "http://$FW/api/identity")
new_status=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$TEMP_PASS" "http://$FW/api/identity")
if [ "$old_status:$new_status" = "401:200" ]; then ok "HTTP Basic auth immediately uses new password"; else bad "HTTP Basic auth immediately uses new password"; fi
AUTH=$TEMP_PASS
post_ok "restore original admin password" system/password "$(jq -nc --arg p "$ORIG_AUTH" '{user:"admin",password:$p}')" >/dev/null || true
AUTH=$ORIG_AUTH
check "original admin credential works again" curl -fsS -u "admin:$AUTH" "http://$FW/api/identity"

say "BIND module API lifecycle and native DNS behavior"
post_ok "POST BIND module install" modules/bind/install '{}' >/dev/null || true
jq_check "BIND module GET reports installed" modules/bind '.modules[0].installed == true'
check "BIND package is really installed" ssh_fw "command -v named >/dev/null && command -v named-checkconf >/dev/null"
post_ok "POST BIND settings" modules/bind/settings '{"listenAddresses":["172.30.60.1"],"allowQuery":["172.30.60.0/24"],"allowTransfer":[],"recursion":false,"recursiveClients":[],"forwarders":[]}' >/dev/null || true
check "named service actually runs" ssh_fw "rc-service named status"
check "BIND owns UDP/53 on LAN address" ssh_fw "ss -lun | grep -E '172.30.60.1:53[[:space:]]'"
post_ok "POST BIND zone add" modules/bind/zoneadd '{"name":"regtest.lan","primaryNs":"ns.regtest.lan","primaryNsAddress":"172.30.60.1","admin":"hostmaster.regtest.lan","ttl":300,"refresh":3600,"retry":600,"expire":1209600,"minimum":300}' >/dev/null || true
j=$(post_ok "POST BIND record add" modules/bind/recordadd '{"zone":"regtest.lan","name":"web","type":"A","value":"172.30.60.11","ttl":300,"priority":""}') || true
RECID=$(printf '%s' "$j" | jq -r '.result.id // empty')
check "BIND answers authoritative record from LAN client" ssh_app2 "nslookup web.regtest.lan $LAN | grep -q '172.30.60.11'"
post_ok "POST BIND service stop" modules/bind/service '{"action":"stop"}' >/dev/null || true
if ssh_fw "rc-service named status" >/dev/null 2>&1; then bad "BIND stop stops native service"; else ok "BIND stop stops native service"; fi
post_ok "POST BIND service start" modules/bind/service '{"action":"start"}' >/dev/null || true
check "BIND start starts native service" ssh_fw "rc-service named status"
post_ok "POST BIND service restart" modules/bind/service '{"action":"restart"}' >/dev/null || true
check "BIND restart leaves native service running" ssh_fw "rc-service named status"
post_ok "POST BIND record delete" modules/bind/recorddelete "$(jq -nc --arg id "$RECID" '{zone:"regtest.lan",id:$id}')" >/dev/null || true
post_ok "POST BIND zone delete" modules/bind/zonedelete '{"name":"regtest.lan"}' >/dev/null || true
post_ok "POST BIND module remove" modules/bind/remove '{}' >/dev/null || true
jq_check "BIND module GET reports removed" modules/bind '.modules[0].installed == false'
check "dnsmasq DNS returns after BIND removal" ssh_fw "rc-service dnsmasq status"

say "OpenVPN module API lifecycle and native tunnel behavior"
post_ok "POST OpenVPN module install" modules/openvpn/install '{}' >/dev/null || true
jq_check "OpenVPN module GET reports installed" modules/openvpn '.modules[0].installed == true'
check "OpenVPN binary and TUN device exist" ssh_fw "command -v openvpn >/dev/null && test -c /dev/net/tun"
post_ok "POST OpenVPN server config" modules/openvpn/server '{"publicHost":"172.30.50.2","inboundInterface":"eth0","interface":"tun0","protocol":"udp","port":1194,"network":"10.99.0.0/24","dns":["172.30.60.1"],"routes":["172.30.60.0/24"],"redirectGateway":false,"clientToClient":false}' >/dev/null || true
check "OpenVPN native service runs" ssh_fw "rc-service openvpn.litefwm status"
check "OpenVPN creates tun0" ssh_fw "ip link show dev tun0"
check "OpenVPN listens on UDP/1194" ssh_fw "ss -lun | grep -E ':1194[[:space:]]'"
check "module firewall rule opens UDP/1194 on eth0" ssh_fw "iptables -S LFW_MOD | grep -q -- '--dport 1194'"
post_ok "POST OpenVPN client add" modules/openvpn/clientadd '{"name":"regclient"}' >/dev/null || true
jq_check "OpenVPN GET shows valid client" modules/openvpn '[.modules[0].state.clients[]|select(.name=="regclient" and .status=="valid")]|length == 1'
j=$(post_ok "POST OpenVPN profile" modules/openvpn/profile '{"name":"regclient"}') || true
if printf '%s' "$j" | jq -e '.result.profile|contains("remote 172.30.50.2 1194")' >/dev/null 2>&1; then ok "OpenVPN profile contains configured endpoint"; else bad "OpenVPN profile contains configured endpoint"; fi
post_ok "POST OpenVPN client revoke" modules/openvpn/clientrevoke '{"name":"regclient"}' >/dev/null || true
jq_check "OpenVPN GET shows revoked client" modules/openvpn '[.modules[0].state.clients[]|select(.name=="regclient" and .status=="revoked")]|length == 1'
post_ok "POST OpenVPN service stop" modules/openvpn/service '{"action":"stop"}' >/dev/null || true
if ssh_fw "rc-service openvpn.litefwm status" >/dev/null 2>&1; then bad "OpenVPN stop stops native service"; else ok "OpenVPN stop stops native service"; fi
post_ok "POST OpenVPN service start" modules/openvpn/service '{"action":"start"}' >/dev/null || true
check "OpenVPN start starts native service" ssh_fw "rc-service openvpn.litefwm status"
post_ok "POST OpenVPN service restart" modules/openvpn/service '{"action":"restart"}' >/dev/null || true
check "OpenVPN restart leaves native service running" ssh_fw "rc-service openvpn.litefwm status"
post_ok "POST OpenVPN module remove" modules/openvpn/remove '{}' >/dev/null || true
jq_check "OpenVPN module GET reports removed" modules/openvpn '.modules[0].installed == false'

say "Dynamic DNS module API lifecycle"
# Local deterministic custom provider endpoints served by the lab outside node.
printf '172.30.50.2\n' >"$LAB/outside-www/ip"
printf 'good\n' >"$LAB/outside-www/update"
post_ok "POST DDNS module install" modules/ddns/install '{}' >/dev/null || true
jq_check "DDNS module GET reports installed" modules/ddns '.modules[0].installed == true'
check "inadyn binary is really installed" ssh_fw "command -v inadyn >/dev/null"
DDNS_BODY='{"provider":"custom","hostnames":["regression.invalid"],"username":"reguser","password":"regpass","period":300,"interface":"eth0","custom":{"checkServer":"172.30.50.100:8088","checkPath":"/ip","updateServer":"172.30.50.100:8088","updatePath":"/update?hostname=%h&myip=%i","ssl":false}}'
post_ok "POST DDNS configure" modules/ddns/configure "$DDNS_BODY" >/dev/null || true
jq_check "DDNS GET reads native inadyn config" modules/ddns '.modules[0].state.configured == true and .modules[0].state.provider == "custom" and (.modules[0].state.hostnames|index("regression.invalid")!=null)'
check "inadyn service is running after configure" ssh_fw "rc-service inadyn status"
j=$(post_ok "POST DDNS force update" modules/ddns/force '{}') || true
if printf '%s' "$j" | jq -e '.ok == true' >/dev/null 2>&1; then ok "DDNS force update completed against local provider"; else bad "DDNS force update completed against local provider"; fi
post_ok "POST DDNS service stop" modules/ddns/service '{"action":"stop"}' >/dev/null || true
if ssh_fw "rc-service inadyn status" >/dev/null 2>&1; then bad "DDNS stop stops native service"; else ok "DDNS stop stops native service"; fi
post_ok "POST DDNS service start" modules/ddns/service '{"action":"start"}' >/dev/null || true
check "DDNS start starts native service" ssh_fw "rc-service inadyn status"
post_ok "POST DDNS service restart" modules/ddns/service '{"action":"restart"}' >/dev/null || true
check "DDNS restart leaves native service running" ssh_fw "rc-service inadyn status"
post_ok "POST DDNS module remove" modules/ddns/remove '{}' >/dev/null || true
jq_check "DDNS module GET reports removed" modules/ddns '.modules[0].installed == false'

say "API guardrails"
status=$(curl -s -o /tmp/lfw2-nohdr.json -w '%{http_code}' -u "admin:$AUTH" -H 'Content-Type: application/json' -d '{}' "http://$FW/api/dns/set")
if [ "$status" = 403 ] && jq -e '.ok==false' /tmp/lfw2-nohdr.json >/dev/null 2>&1; then ok "mutations require X-LiteFWM header"; else bad "mutations require X-LiteFWM header"; fi
status=$(curl -s -o /tmp/lfw2-badroute.json -w '%{http_code}' -u "admin:$AUTH" "http://$FW/api/no-such-resource")
if [ "$status" = 404 ]; then ok "unknown resource returns 404"; else bad "unknown resource returns 404"; fi

printf '\nAPI regression: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
