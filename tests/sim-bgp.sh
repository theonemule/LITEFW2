#!/bin/sh
# Real BGP convergence and import/export policy tests in an ephemeral Docker netns.
set -eu
cd /workspace
echo 'CASE bgp/build-two-routers'
ip netns add lfw_bgppeer
ip link add lfw_bgp0 type veth peer name lfw_bgp1
ip link set lfw_bgp1 netns lfw_bgppeer
ip addr add 10.203.0.1/30 dev lfw_bgp0
ip link set lfw_bgp0 up
ip netns exec lfw_bgppeer ip link set lo up
ip netns exec lfw_bgppeer ip addr add 10.203.0.2/30 dev lfw_bgp1
ip netns exec lfw_bgppeer ip link set lfw_bgp1 up
ip netns exec lfw_bgppeer ping -n -c 1 -W 2 10.203.0.1 >/dev/null
# The network originated by LiteFW must genuinely exist in its RIB.
ip route add blackhole 10.91.0.0/24

cat >/tmp/lfw-peer.conf <<'BIRD'
log stderr all;
router id 10.203.0.2;
protocol device { }
protocol static lfw_bad_route {
  ipv4;
  route 10.99.0.0/24 blackhole;
}
protocol bgp lfw_peer {
  local as 64513;
  neighbor 10.203.0.1 as 64512;
  ipv4 {
    import all;
    export where net = 10.99.0.0/24;
  };
}
BIRD
bird -p -c /tmp/lfw-peer.conf >/tmp/lfw-bird-syntax.log 2>&1 || {
  cat /tmp/lfw-bird-syntax.log >&2; exit 1;
}

mkdir -p /tmp/lfw-bgp-config /run/frr
export LFW_MODULE_CONFIG_DIR=/tmp/lfw-bgp-config
jq -n '{asn:64512,routerId:"10.203.0.1",neighbors:[{address:"10.203.0.2",remoteAs:64513}],networks:["10.91.0.0/24"]}' >/tmp/lfw-bgp-req.json
/workspace/modules/frr/module.sh configure /tmp/lfw-bgp-req.json >/tmp/lfw-bgp-state.json
jq -e '.running==false and .configured==true' /tmp/lfw-bgp-state.json >/dev/null
# The exact FRR file produced by LiteFW is dry-run validated by bgpd.
/usr/lib/frr/bgpd -C -f /etc/frr/frr.conf >/tmp/lfw-bgpd-validate.log 2>&1 || {
  cat /tmp/lfw-bgpd-validate.log >&2; exit 1;
}
grep -Fq 'route-map LFW-IN deny 10' /etc/frr/frr.conf
grep -Fq 'ip prefix-list LFW-EXPORT seq 10 permit 10.91.0.0/24' /etc/frr/frr.conf
echo 'PASS LiteFW creates an FRR-accepted config and explicit import/export policies'

echo 'CASE bgp/peering-and-route-policy'
# -Z means standalone bgpd (no zebra dependency); all sockets are inside Docker.
/usr/lib/frr/bgpd -d -Z -S -f /etc/frr/frr.conf -i /run/frr/bgpd.pid \
  --vty_socket /run/frr >/tmp/lfw-bgpd-start.log 2>&1 || {
  cat /tmp/lfw-bgpd-start.log >&2; exit 1;
}
ip netns exec lfw_bgppeer bird -c /tmp/lfw-peer.conf -s /tmp/lfw-bird.ctl \
  >/tmp/lfw-bird.log 2>&1
# The peer exports 10.99.0.0/24 to LiteFW and accepts LiteFW's 10.91.0.0/24.
# Poll for both control-plane convergence and actual advertised NLRI.
established=false
for attempt in $(seq 1 25); do
  if vtysh -d bgpd -c 'show bgp ipv4 unicast summary json' 2>/dev/null |
     jq -e '.ipv4Unicast.peers["10.203.0.2"].state == "Established" or .peers["10.203.0.2"].state == "Established"' >/dev/null 2>&1; then
    established=true
    break
  fi
  sleep 1
done
[ "$established" = true ] || {
  echo 'BGP never reached Established' >&2
  vtysh -d bgpd -c 'show bgp ipv4 unicast summary json' >&2 || :
  cat /tmp/lfw-bgpd-start.log >&2; cat /tmp/lfw-bird.log >&2; exit 1;
}
echo 'PASS FRRouting and BIRD reached BGP Established over real veth peers'

for attempt in $(seq 1 15); do
  if ip netns exec lfw_bgppeer birdc -s /tmp/lfw-bird.ctl show route 2>/dev/null |
    grep -Fq '10.91.0.0/24'; then break; fi
  sleep 1
done
ip netns exec lfw_bgppeer birdc -s /tmp/lfw-bird.ctl show route | grep -Fq '10.91.0.0/24'
echo 'PASS explicit configured LiteFW IPv4 prefix advertised to BGP peer'
# Peer exports its route but LiteFW's LFW-IN route map denies acceptance.
ip netns exec lfw_bgppeer birdc -s /tmp/lfw-bird.ctl show route export lfw_peer |
  grep -Fq '10.99.0.0/24'
# If route was accepted it would be visible in BGP RIB with valid path.
if vtysh -d bgpd -c 'show bgp ipv4 unicast' | grep -Fq '10.99.0.0/24'; then
  echo 'FAIL a remote route crossed the deny-all BGP inbound route policy' >&2; exit 1
fi
echo 'PASS unsolicited BGP prefix is rejected by LiteFW inbound policy'

echo 'CASE bgp/session-down-and-reconnect'
ip netns exec lfw_bgppeer birdc -s /tmp/lfw-bird.ctl disable lfw_peer >/dev/null
for attempt in $(seq 1 15); do
  if ! vtysh -d bgpd -c 'show bgp ipv4 unicast summary json' |
    jq -e '.ipv4Unicast.peers["10.203.0.2"].state == "Established" or .peers["10.203.0.2"].state == "Established"' >/dev/null 2>&1; then break; fi
  sleep 1
done
if vtysh -d bgpd -c 'show bgp ipv4 unicast summary json' |
  jq -e '.ipv4Unicast.peers["10.203.0.2"].state == "Established" or .peers["10.203.0.2"].state == "Established"' >/dev/null 2>&1; then
  echo 'FAIL session did not transition out of Established' >&2; exit 1
fi
ip netns exec lfw_bgppeer birdc -s /tmp/lfw-bird.ctl enable lfw_peer >/dev/null
for attempt in $(seq 1 25); do
  if vtysh -d bgpd -c 'show bgp ipv4 unicast summary json' 2>/dev/null |
    jq -e '.ipv4Unicast.peers["10.203.0.2"].state == "Established" or .peers["10.203.0.2"].state == "Established"' >/dev/null 2>&1; then
    echo 'PASS peer down/up transitions recover an Established BGP session'
    exit 0
  fi
  sleep 1
done
echo 'FAIL BGP session did not recover after peer returned' >&2
exit 1
