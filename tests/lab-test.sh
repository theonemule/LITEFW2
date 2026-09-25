#!/bin/bash
# Functional test suite for the LiteFWM lab (see tests/lab.sh).
# Every change goes through the real HTTP API (lighttpd -> CGI -> sudo lfwctl).
set -u
P=lfwlab
. /tmp/$P.env
D="sudo docker"
x() { local c=$1; shift; $D exec "$P-$c" sh -c "$*"; }
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
section() { printf '\n== %s\n' "$*"; }

FWIP=$(x fw "ip -4 -o addr show dev $WAN | awk '{print \$4}' | cut -d/ -f1 | head -n1")
API=${LFW_API:-http://$FWIP}
AUTH=admin:labpass123
op() { curl -s -m 90 -u $AUTH -H 'X-LiteFWM: 1' -H 'Content-Type: application/json' -d "$2" "$API/api/op/$1"; }
opok() { local r; r=$(op "$1" "$2"); if printf '%s' "$r" | jq -e .ok >/dev/null 2>&1; then pass "$1 $2"; LAST=$r; else fail "$1 $2 -> $r"; LAST=$r; fi; }
opfail() { local r; r=$(op "$1" "$2"); if printf '%s' "$r" | jq -e '.ok==false' >/dev/null 2>&1; then pass "rejected: $1 ($(printf '%s' "$r" | jq -r .error))"; else fail "should be rejected: $1 $2 -> $r"; fi; }
state() { curl -s -m 60 -u $AUTH "$API/api/state"; }
sj() { state | jq -e "$@"; }
iface() { state | jq -c --arg n "$1" '.interfaces[] | select(.name==$n)'; }

section "API and authentication"
check "unauthenticated request is refused" test "$(curl -s -o /dev/null -w '%{http_code}' $API/api/state)" = 401
check "authenticated state" sj '.interfaces | length > 0'
check "change without X-LiteFWM header is refused" test "$(curl -s -o /dev/null -w '%{http_code}' -u $AUTH -d '{}' $API/api/op/system.set)" = 403
check "WAN adopted from the running system (DHCP, role wan)" sj --arg w "$WAN" '.interfaces[] | select(.name==$w) | .role=="wan" and .mode=="dhcp"'
check "masquerade follows WAN" sj --arg w "$WAN" '.firewall.masquerade == [$w]'
check "default policies are DROP" sj '.firewall.policies.INPUT=="DROP" and .firewall.policies.FORWARD=="DROP"'

section "LAN segment + DHCP server"
opok segment.set "{\"interface\":\"$LAN\",\"label\":\"LAN\",\"role\":\"lan\",\"mode\":\"static\",\"addresses\":[\"192.168.10.1/24\"]}"
check "LAN address live in kernel" x fw "ip -4 addr show dev $LAN | grep -q 192.168.10.1/24"
opfail dhcpd.set "{\"interface\":\"$LAN\",\"enabled\":true,\"start\":\"192.168.10.1\",\"end\":\"192.168.10.9\"}"
opfail dhcpd.set "{\"interface\":\"$LAN\",\"enabled\":true,\"start\":\"192.168.20.100\",\"end\":\"192.168.20.150\"}"
opok dhcpd.set "{\"interface\":\"$LAN\",\"enabled\":true,\"start\":\"192.168.10.100\",\"end\":\"192.168.10.150\",\"leaseTime\":\"1h\",\"domain\":\"lan\"}"
check "dnsmasq running" x fw "pidof dnsmasq"
x lan1 'udhcpc -i eth0 -n -q -t 5 -T 2 >/tmp/udhcpc.log 2>&1'
L1IP=$(x lan1 "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1")
check "lan1 got a lease from the firewall ($L1IP)" sh -c "case '$L1IP' in 192.168.10.1[0-5][0-9]) true;; *) false;; esac"
check "lan1 default route via 192.168.10.1" x lan1 "ip route | grep -q 'default via 192.168.10.1'"
check "lease visible in state" sj --arg ip "$L1IP" '[.dhcp.leases[] | select(.ip==$ip)] | length==1'
check "LAN may query the firewall's DNS" x lan1 "nslookup internet.test 192.168.10.1 | grep -q 10.250.0.2"

section "Default deny and forwarding rules"
check "LAN -> internet blocked by default" sh -c "! sudo docker exec $P-lan1 wget -q -T 3 -O - http://10.250.0.2/cgi-bin/ip"
opok rule.add "{\"chain\":\"forward\",\"action\":\"accept\",\"in\":\"$LAN\",\"out\":\"$WAN\",\"description\":\"LAN to internet\"}"
R_LANWAN=$(printf '%s' "$LAST" | jq -r .result.id)
SRC=$(x lan1 'wget -q -T 5 -O - http://10.250.0.2/cgi-bin/ip' | sed 's/^\[::ffff://; s/\]$//')
check "LAN -> internet allowed, source NATed to WAN ($SRC)" test "$SRC" = "$FWIP"
opok rule.add "{\"chain\":\"forward\",\"action\":\"reject\",\"in\":\"$LAN\",\"out\":\"$WAN\",\"src\":\"$L1IP\",\"proto\":\"tcp\",\"ports\":\"80\",\"description\":\"block lan1 web\",\"position\":0}"
R_BLOCK=$(printf '%s' "$LAST" | jq -r .result.id)
check "specific host/port reject rule (first) blocks lan1" sh -c "! sudo docker exec $P-lan1 wget -q -T 3 -O - http://10.250.0.2/cgi-bin/ip"
check "rule order in kernel: reject before accept" sj --arg a "$R_BLOCK" --arg b "$R_LANWAN" '[.firewall.rules[] | select(.chain=="forward") | .id] == [$a,$b]'
opok rule.move "{\"id\":\"$R_BLOCK\",\"position\":1}"
check "after move, accept wins again" x lan1 'wget -q -T 5 -O - http://10.250.0.2/cgi-bin/ip'
opok rule.update "{\"id\":\"$R_BLOCK\",\"chain\":\"forward\",\"action\":\"drop\",\"in\":\"$LAN\",\"out\":\"$WAN\",\"src\":\"192.168.10.0/24\",\"proto\":\"udp\",\"ports\":\"5000-5010,6000\",\"description\":\"udp range\"}"
check "update parsed back from iptables" sj --arg a "$R_BLOCK" '.firewall.rules[] | select(.id==$a) | .action=="drop" and .proto=="udp" and .ports=="5000-5010,6000" and .src=="192.168.10.0/24" and .managed'
opok rule.delete "{\"id\":\"$R_BLOCK\"}"
opfail rule.add "{\"chain\":\"forward\",\"in\":\"nosuch0\"}"
opfail rule.add "{\"chain\":\"forward\",\"proto\":\"any\",\"ports\":\"80\"}"
opfail rule.add "{\"chain\":\"forward\",\"description\":\"bad\\\"; rm -rf /\"}"
check "WAN ping to firewall blocked by default" sh -c "! sudo docker exec $P-isp ping -c1 -W2 $FWIP"
opok rule.add "{\"chain\":\"input\",\"action\":\"accept\",\"in\":\"$WAN\",\"proto\":\"icmp\",\"description\":\"ping from WAN\"}"
check "input rule: WAN ping allowed" x isp "ping -c1 -W2 $FWIP"

section "Port forward (DNAT)"
x lan1 'pkill httpd; busybox-extras httpd -p 80 -h /www'
opok forward.add "{\"proto\":\"tcp\",\"port\":\"8080\",\"to\":\"$L1IP\",\"toPort\":\"80\",\"description\":\"lan1 web\"}"
F1=$(printf '%s' "$LAST" | jq -r .result.id)
check "internet -> WAN:8080 reaches lan1:80" sh -c "sudo docker exec $P-isp wget -q -T 5 -O - http://$FWIP:8080/ | grep -q 'hello from lan1'"
check "port forward read back from kernel" sj --arg f "$F1" --arg w "$WAN" '.firewall.forwards[] | select(.id==$f) | .in==$w and .port=="8080" and .toPort=="80"'
opok forward.update "{\"id\":\"$F1\",\"proto\":\"both\",\"port\":\"8081\",\"to\":\"$L1IP\",\"toPort\":\"80\",\"description\":\"lan1 web\"}"
check "updated forward (tcp+udp, 8081) works" sh -c "sudo docker exec $P-isp wget -q -T 5 -O - http://$FWIP:8081/ | grep -q 'hello from lan1'"
check "old port no longer forwarded" sh -c "! sudo docker exec $P-isp wget -q -T 3 -O - http://$FWIP:8080/"

section "DHCP lease -> reservation"
L1MAC=$(x lan1 'cat /sys/class/net/eth0/address')
opok reservation.add "{\"mac\":\"$L1MAC\",\"ip\":\"192.168.10.50\",\"hostname\":\"lan1\"}"
opfail reservation.add "{\"mac\":\"02:00:00:00:00:99\",\"ip\":\"192.168.10.50\"}"
opfail reservation.add "{\"mac\":\"02:00:00:00:00:98\",\"ip\":\"$L1IP\"}"
check "lease shows as reserved" sj --arg m "$L1MAC" '.dhcp.leases[] | select(.mac==$m) | .reserved and .reservedIp=="192.168.10.50"'
x lan1 'ip -4 addr flush dev eth0; udhcpc -i eth0 -n -q -t 5 -T 2 >/dev/null 2>&1'
check "client now receives the reserved address" x lan1 "ip -4 addr show dev eth0 | grep -q 192.168.10.50/24"
check "reserved hostname resolves (lan1.lan)" x lan1 "nslookup lan1.lan 192.168.10.1 | grep -q 192.168.10.50"
L1IP=192.168.10.50
opok forward.update "{\"id\":\"$F1\",\"proto\":\"tcp\",\"port\":\"8080\",\"to\":\"$L1IP\",\"toPort\":\"80\",\"description\":\"lan1 web\"}"

section "DNS settings"
opok dns.set '{"domain":"home.arpa","upstream":["10.250.0.2"],"hosts":[{"name":"nas","ip":"192.168.10.5"}]}'
check "host record resolves" x lan1 "nslookup nas.home.arpa 192.168.10.1 | grep -q 192.168.10.5"
check "upstream forwarding works" x lan1 "nslookup internet.test 192.168.10.1 | grep -q 10.250.0.2"
opok dns.set '{"domain":"lan","upstream":[],"hosts":[]}'

section "VLAN-aware bridge on the trunk + VLAN segment"
opok bridge.create "{\"name\":\"br1\",\"vlanFiltering\":true,\"members\":[\"$TRUNK\"]}"
opok vlan.create '{"parent":"br1","vid":20}'
check "br1.20 exists, VLAN 20 on bridge self and trunk port" sj --arg t "$TRUNK" '.interfaces[] | select(.name=="br1") | ([.bridgeVlans[] | select(.port=="br1") | .vlans[].vid] | index(20) != null) and ([.bridgeVlans[] | select(.port==$t) | .vlans[].vid] | index(20) != null)'
opok segment.set '{"interface":"br1.20","label":"IoT","role":"lan","mode":"static","addresses":["192.168.20.1/24"]}'
opok dhcpd.set '{"interface":"br1.20","enabled":true,"start":"192.168.20.100","end":"192.168.20.199"}'
x trunk1 'ip link add link eth0 name eth0.20 type vlan id 20 2>/dev/null; ip link set eth0.20 up; udhcpc -i eth0.20 -n -q -t 5 -T 2 >/dev/null 2>&1'
T1IP=$(x trunk1 "ip -4 -o addr show dev eth0.20 | awk '{print \$4}' | cut -d/ -f1")
check "tagged client on VLAN 20 got a lease ($T1IP)" sh -c "case '$T1IP' in 192.168.20.1[0-9][0-9]) true;; *) false;; esac"
check "segments isolated by default (IoT -> LAN blocked)" sh -c "! sudo docker exec $P-trunk1 wget -q -T 3 -O - http://$L1IP/"
opok rule.add "{\"chain\":\"forward\",\"action\":\"accept\",\"in\":\"br1.20\",\"out\":\"$LAN\",\"dst\":\"$L1IP\",\"proto\":\"tcp\",\"ports\":\"80\",\"description\":\"IoT to lan1 web\"}"
check "IoT -> lan1:80 allowed by rule" sh -c "sudo docker exec $P-trunk1 wget -q -T 5 -O - http://$L1IP/ | grep -q 'hello from lan1'"
check "LAN -> IoT still blocked (no rule)" sh -c "! sudo docker exec $P-lan1 ping -c1 -W2 $T1IP"
opok bridge.portvlans "{\"bridge\":\"br1\",\"port\":\"$TRUNK\",\"pvid\":1,\"tagged\":[20,30]}"
check "port VLANs read back" sj --arg t "$TRUNK" '.interfaces[] | select(.name=="br1") | .bridgeVlans[] | select(.port==$t) | ([.vlans[].vid] == [1,20,30]) and (.vlans[0].pvid)'
opfail vlan.delete '{"name":"br1.20"}'
opfail bridge.delete '{"name":"br1"}'

section "Bridge an addressed NIC: WAN moves into br0 (through the WAN itself)"
x isp "ping -i 0.2 -c 100 -W 1 $FWIP > /tmp/ping.log 2>&1 &"
WANMAC=$(x fw "cat /sys/class/net/$WAN/address")
opok bridge.create "{\"name\":\"br0\",\"members\":[\"$WAN\"]}"
sleep 1
check "br0 carries the same WAN address" x fw "ip -4 addr show dev br0 | grep -q $FWIP/"
check "br0 kept the NIC's MAC (same DHCP identity)" test "$(x fw 'cat /sys/class/net/br0/address')" = "$WANMAC"
check "br0 is WAN, on DHCP, NIC is a port with no address" sj --arg w "$WAN" '(.interfaces[] | select(.name=="br0") | .role=="wan" and .mode=="dhcp") and (.interfaces[] | select(.name==$w) | .master=="br0" and (.addresses|length)==0 and .role=="none")'
check "default route moved to br0" x fw "ip route show default | grep -q 'dev br0'"
check "masquerade moved to br0" sj '.firewall.masquerade == ["br0"]'
check "firewall rules follow the WAN (out=br0)" sj --arg r "$R_LANWAN" '.firewall.rules[] | select(.id==$r) | .out=="br0"'
check "port forward follows the WAN (in=br0)" sj --arg f "$F1" '.firewall.forwards[] | select(.id==$f) | .in=="br0"'
check "LAN internet still works" x lan1 'wget -q -T 5 -O - http://10.250.0.2/cgi-bin/ip'
check "port forward still works" sh -c "sudo docker exec $P-isp wget -q -T 5 -O - http://$FWIP:8080/ | grep -q 'hello from lan1'"
sleep 21
LOSS=$(x isp "grep -o '[0-9]* packets received' /tmp/ping.log | cut -d' ' -f1")
echo "       pings answered during migration: ${LOSS:-?}/100"
check "management path survived the migration (>=95/100 pings)" test "${LOSS:-0}" -ge 95

section "Management access guard"
opfail mgmt.set "{\"access\":[\"$LAN\"]}"
opok mgmt.set '{"access":["br0","'"$LAN"'"]}'
check "management restricted to br0 + LAN" sj --arg l "$LAN" '.system.management.access == (["br0",$l]|sort)'
opok mgmt.set '{"access":"any"}'
opok system.set '{"hostname":"edge1"}'
check "hostname live" test "$(x fw hostname)" = edge1

section "Reboot: tear down the running state, boot from native files only"
before=$(state | jq -S '{i:[.interfaces | sort_by(.name) | .[] | {name,kind,master,members,parent,vid,vlanFiltering,role,label,mode,addresses:(.addresses|sort),mtu,bridgeVlans}], r:[.firewall.rules[] | del(.raw)], f:[.firewall.forwards[] | del(.raw)], m:.firewall.masquerade, d:[.interfaces | sort_by(.name) | .[] | {name,dhcpServer}], res:.dhcp.reservations, dns:.dns}')
x fw 'rc-service lighttpd stop >/dev/null 2>&1; rc-service dnsmasq stop >/dev/null 2>&1
  for p in /var/run/udhcpc.*.pid; do kill -9 $(cat $p) 2>/dev/null; rm -f $p; done
  for i in $(ls /sys/class/net); do k=$(ip -d -j link show dev $i | jq -r ".[0].linkinfo.info_kind // empty"); case $k in bridge|vlan) ip link del $i 2>/dev/null;; esac; done
  for i in $(ls /sys/class/net); do [ $i = lo ] || { ip -4 addr flush dev $i; ip link set dev $i alias ""; }; done
  ip route flush table main
  iptables-restore </dev/null; for t in filter nat; do iptables -t $t -F; iptables -t $t -X; done; iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT
  rm -rf /run/ifstate* /run/litefwm'
check "teardown removed bridges" sh -c "! sudo docker exec $P-fw ip link show br0"
x fw 'rc-service iptables start >/dev/null 2>&1 || iptables-restore < /etc/iptables/rules-save
  ifup -a >/tmp/ifup.log 2>&1
  rc-service dnsmasq start >/dev/null 2>&1; rc-service lighttpd start >/dev/null 2>&1'
sleep 3
after=$(state | jq -S '{i:[.interfaces | sort_by(.name) | .[] | {name,kind,master,members,parent,vid,vlanFiltering,role,label,mode,addresses:(.addresses|sort),mtu,bridgeVlans}], r:[.firewall.rules[] | del(.raw)], f:[.firewall.forwards[] | del(.raw)], m:.firewall.masquerade, d:[.interfaces | sort_by(.name) | .[] | {name,dhcpServer}], res:.dhcp.reservations, dns:.dns}')
if [ -n "$before" ] && [ "$before" = "$after" ]; then pass "state after boot is identical to state before"; else
  fail "state differs after boot"; diff <(printf '%s' "$before" | jq .) <(printf '%s' "$after" | jq .) | head -40; fi
check "LAN internet after boot" x lan1 'wget -q -T 5 -O - http://10.250.0.2/cgi-bin/ip'
check "IoT DHCP after boot" x trunk1 'ip -4 addr flush dev eth0.20; udhcpc -i eth0.20 -n -q -t 5 -T 2 >/dev/null 2>&1 && ip -4 addr show dev eth0.20 | grep -q 192.168.20.'
check "port forward after boot" sh -c "sudo docker exec $P-isp wget -q -T 5 -O - http://$FWIP:8080/ | grep -q 'hello from lan1'"

section "Un-bridge: deleting br0 hands the WAN back to the NIC"
opok bridge.delete '{"name":"br0"}'
sleep 1
check "NIC has the WAN address again, DHCP, role wan" sj --arg w "$WAN" --arg ip "$FWIP" '.interfaces[] | select(.name==$w) | .role=="wan" and .mode=="dhcp" and (.addresses[0] | startswith($ip + "/"))'
check "rules follow back to the NIC" sj --arg r "$R_LANWAN" --arg w "$WAN" '.firewall.rules[] | select(.id==$r) | .out==$w'
check "LAN internet works" x lan1 'wget -q -T 5 -O - http://10.250.0.2/cgi-bin/ip'
check "boot file has no br0" sh -c "! sudo docker exec $P-fw grep -q br0 /etc/network/interfaces"

section "Clean-up operations"
R_IOT=$(state | jq -r '.firewall.rules[] | select(.in=="br1.20") | .id')
opok rule.delete "{\"id\":\"$R_IOT\"}"
opok segment.set '{"interface":"br1.20","role":"none","mode":"none"}'
check "DHCP server removed with the LAN role" sj '.interfaces[] | select(.name=="br1.20") | .dhcpServer.enabled==false'
opok vlan.delete '{"name":"br1.20"}'
opok bridge.delete '{"name":"br1"}'
opok reservation.delete "{\"mac\":\"$L1MAC\"}"
opok forward.delete "{\"id\":\"$F1\"}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
