#!/bin/sh
# Prove native nftables forwarding, outbound masquerade and inbound DNAT.
# Execute only in a disposable privileged Alpine test container.
set -eu
apk add -q --no-cache nftables iproute2 jq python3 openssh >/dev/null
mkdir -p /tmp/lfw-packet
export LFW_LIB=/src/lib LFW_FW_SAVE=/tmp/lfw-packet/boot.nft LFW_RUN=/tmp/lfw-packet
ctl() { /src/bin/lfwctl "$@"; }
cleanup() {
  ip netns del lfw_inside 2>/dev/null || true
  ip netns del lfw_outside 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
ip netns add lfw_inside
ip netns add lfw_outside
ip link add lfw_l0 type veth peer name lfw_c0
ip link add lfw_w0 type veth peer name lfw_s0
ip link set lfw_c0 netns lfw_inside
ip link set lfw_s0 netns lfw_outside
ip link set lfw_l0 up
ip link set lfw_w0 up
ip addr add 10.80.1.1/24 dev lfw_l0
ip addr add 10.80.2.1/24 dev lfw_w0
ip link set dev lfw_l0 alias 'lfw:role=lan;name=LAN'
ip link set dev lfw_w0 alias 'lfw:role=wan;name=WAN'
ip netns exec lfw_inside ip addr add 10.80.1.2/24 dev lfw_c0
ip netns exec lfw_inside ip link set lfw_c0 up
ip netns exec lfw_inside ip link set lo up
ip netns exec lfw_inside ip route add default via 10.80.1.1
ip netns exec lfw_outside ip addr add 10.80.2.2/24 dev lfw_s0
ip netns exec lfw_outside ip link set lfw_s0 up
ip netns exec lfw_outside ip link set lo up
sysctl -w net.ipv4.ip_forward=1 >/dev/null

ctl persist
ctl op rule.add '{"chain":"forward","in":"lfw_l0","out":"lfw_w0","proto":"udp","ports":"9999","action":"accept","description":"test UDP egress"}' | jq -e .ok >/dev/null
ip netns exec lfw_outside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("10.80.2.2",9999)); s.settimeout(5)
data,peer=s.recvfrom(100)
open("/tmp/lfw-packet/observed-egress","w").write(peer[0]+":"+data.decode())
' &
receiver=$!
sleep 0.2
ip netns exec lfw_inside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.sendto(b"hello",("10.80.2.2",9999))
'
wait "$receiver"
[ "$(cat /tmp/lfw-packet/observed-egress)" = '10.80.2.1:hello' ] ||
  { echo "Outbound NAT failed: $(cat /tmp/lfw-packet/observed-egress)" >&2; exit 1; }

ctl op forward.add '{"in":"lfw_w0","proto":"udp","port":"8443","to":"10.80.1.2","toPort":"443","description":"DNAT test"}' | jq -e .ok >/dev/null
ip netns exec lfw_inside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("10.80.1.2",443)); s.settimeout(5)
data,peer=s.recvfrom(100)
open("/tmp/lfw-packet/observed-dnat","w").write(data.decode())
' &
receiver=$!
sleep 0.2
ip netns exec lfw_outside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.sendto(b"forwarded",("10.80.2.1",8443))
'
wait "$receiver"
[ "$(cat /tmp/lfw-packet/observed-dnat)" = 'forwarded' ] || {
  echo 'Inbound DNAT failed' >&2; exit 1;
}
# Two custom rules both match the same routed packet. Confirm the first
# matching rule wins, not merely that ordered rule text looks correct.
accept_id=$(ctl op rule.add '{"chain":"forward","in":"lfw_l0","out":"lfw_w0","proto":"udp","ports":"9998","action":"accept","description":"allow test order"}' | jq -er '.result.id')
deny_id=$(ctl op rule.add '{"chain":"forward","in":"lfw_l0","out":"lfw_w0","proto":"udp","ports":"9998","action":"drop","position":"0","description":"block test order"}' | jq -er '.result.id')
ip netns exec lfw_outside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("10.80.2.2",9998)); s.settimeout(2)
try:
  s.recvfrom(100)
  raise SystemExit("FAIL first matching drop failed")
except socket.timeout:
  pass
' &
receiver=$!
sleep 0.2
ip netns exec lfw_inside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.sendto(b"blocked",("10.80.2.2",9998))
'
wait "$receiver"
ctl op rule.move "$(jq -nc --arg id "$deny_id" '{id:$id,position:2}')" | jq -e .ok >/dev/null
ip netns exec lfw_outside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("10.80.2.2",9998)); s.settimeout(3)
data,_=s.recvfrom(100)
if data!=b"allowed": raise SystemExit("FAIL first matching allow failed")
' &
receiver=$!
sleep 0.2
ip netns exec lfw_inside python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.sendto(b"allowed",("10.80.2.2",9998))
'
wait "$receiver"
echo 'PASS: real routed UDP packets, outbound SNAT/masquerade, DNAT and first-match priority'
