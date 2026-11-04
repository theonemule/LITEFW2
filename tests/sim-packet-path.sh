#!/bin/sh
# Shared routed packet fixture for GeoIP / connectivity tests.
# Runs only in an isolated privileged disposable Alpine container.
set -eu
[ -f /.dockerenv ] || { echo 'Requires isolated Docker network namespace' >&2; exit 1; }
echo 'CASE network/isolated-packet-path'
ip netns add lfw_ics
ip netns add lfw_isv
ip link add lfw_in type veth peer name lfw_ci
ip link set lfw_ci netns lfw_ics
ip link add lfw_out type veth peer name lfw_si
ip link set lfw_si netns lfw_isv
ip addr add 192.0.2.1/24 dev lfw_in
ip addr add 198.51.100.1/24 dev lfw_out
ip link set lfw_in up
ip link set lfw_out up
ip netns exec lfw_ics ip link set lo up
ip netns exec lfw_isv ip link set lo up
ip netns exec lfw_ics ip addr add 192.0.2.2/24 dev lfw_ci
ip netns exec lfw_isv ip addr add 198.51.100.2/24 dev lfw_si
ip netns exec lfw_ics ip link set lfw_ci up
ip netns exec lfw_isv ip link set lfw_si up
ip netns exec lfw_ics ip route add default via 192.0.2.1
ip netns exec lfw_isv ip route add default via 198.51.100.1
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -P FORWARD ACCEPT
iptables -N LFW_FWD
iptables -A FORWARD -j LFW_FWD
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
echo 'PASS synthetic LAN/WAN packet forwarding works with no filters'
