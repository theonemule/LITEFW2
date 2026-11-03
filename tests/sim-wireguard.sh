#!/bin/sh
# WireGuard encrypted packet test using the real Linux WG tunnel driver.
set -eu
cd /workspace
echo 'CASE wireguard/native-config-and-encrypted-peering'
mkdir -p /tmp/lfw-wg-conf /etc/wireguard
export LFW_MODULE_CONFIG_DIR=/tmp/lfw-wg-conf
umask 077
wg genkey >/tmp/lfw-wg-root.key
wg genkey >/tmp/lfw-wg-peer.key
wg pubkey </tmp/lfw-wg-root.key >/tmp/lfw-wg-root.pub
wg pubkey </tmp/lfw-wg-peer.key >/tmp/lfw-wg-peer.pub

ip netns add lfw_wgpeer
ip link add lfw_under0 type veth peer name lfw_under1
ip link set lfw_under1 netns lfw_wgpeer
ip addr add 172.27.0.1/30 dev lfw_under0
ip link set lfw_under0 up
ip netns exec lfw_wgpeer ip link set lo up
ip netns exec lfw_wgpeer ip addr add 172.27.0.2/30 dev lfw_under1
ip netns exec lfw_wgpeer ip link set lfw_under1 up
ip netns exec lfw_wgpeer ping -n -c 1 -W 2 172.27.0.1 >/dev/null

jq -n --arg key "$(cat /tmp/lfw-wg-root.key)" --arg peer "$(cat /tmp/lfw-wg-peer.pub)" '{
  interface:"wg0",address:"10.222.0.1/24",listenPort:51999,privateKey:$key,
  peers:[{publicKey:$peer,allowedIPs:"10.222.0.2/32",endpoint:"127.0.0.1:52000",persistentKeepalive:1}]
}' >/tmp/lfw-wg-request.json
/workspace/modules/wireguard/module.sh configure /tmp/lfw-wg-request.json > /tmp/lfw-wg-snapshot.json
test "$(stat -c %a /etc/wireguard/wg0.conf)" = 600
bash /usr/bin/wg-quick strip wg0 >/tmp/lfw-wg-stripped.conf
grep -Fq "PublicKey = $(cat /tmp/lfw-wg-peer.pub)" /etc/wireguard/wg0.conf
jq -e '.settings.credentialConfigured==true and .settings.privateKey==null' /tmp/lfw-wg-snapshot.json >/dev/null
if grep -Fq "$(cat /tmp/lfw-wg-root.key)" /tmp/lfw-wg-snapshot.json; then
  echo 'FAIL WireGuard private key returned by API snapshot' >&2; exit 1
fi
bash /usr/bin/wg-quick up wg0 >/tmp/lfw-wg-up.log 2>&1 || {
  cat /tmp/lfw-wg-up.log >&2; exit 1;
}
# WireGuard keeps its UDP socket in the namespace in which its interface
# was created. Create/configure wg1 in the disposable router namespace, then
# move the *inner tunnel interface* to the test peer. Underlay stays on the
# isolated router loopback; the tunnel data plane crosses the namespace.
cat >/etc/wireguard/wg1.conf <<EOF
[Interface]
PrivateKey = $(cat /tmp/lfw-wg-peer.key)
ListenPort = 52000
[Peer]
PublicKey = $(cat /tmp/lfw-wg-root.pub)
AllowedIPs = 10.222.0.1/32
Endpoint = 127.0.0.1:51999
PersistentKeepalive = 1
EOF
chmod 0600 /etc/wireguard/wg1.conf
bash /usr/bin/wg-quick up wg1 >/tmp/lfw-wg-peer-up.log 2>&1 || {
  cat /tmp/lfw-wg-peer-up.log >&2; exit 1;
}
ip link set wg1 netns lfw_wgpeer
ip netns exec lfw_wgpeer ip addr add 10.222.0.2/24 dev wg1
ip netns exec lfw_wgpeer ip link set wg1 up

echo 'CASE wireguard/data-plane-and-handshake'
for attempt in 1 2 3 4 5; do
  if ip netns exec lfw_wgpeer ping -n -c 1 -W 2 -I wg1 10.222.0.1 >/dev/null 2>&1; then break; fi
  sleep 1
done
ip netns exec lfw_wgpeer ping -n -c 2 -W 2 -I wg1 10.222.0.1 >/dev/null
wg show wg0 latest-handshakes | awk '{if($2>0) seen=1} END{exit !seen}'
rules=$(/workspace/modules/wireguard/module.sh firewall)
printf '%s\n' "$rules" | grep -Fq -- '-A LFW_MOD -p udp --dport 51999'
echo 'PASS encrypted WireGuard tunnel carries ICMP with fresh handshake and UDP firewall rule'

echo 'CASE wireguard/rekey-preservation-and-validation'
jq '.privateKey=""' /tmp/lfw-wg-request.json >/tmp/lfw-wg-edit.json
/workspace/modules/wireguard/module.sh configure /tmp/lfw-wg-edit.json >/dev/null
grep -Fq "PrivateKey = $(cat /tmp/lfw-wg-root.key)" /etc/wireguard/wg0.conf
jq '.address="999.0.0.1/33"' /tmp/lfw-wg-request.json >/tmp/lfw-wg-bad.json
if /workspace/modules/wireguard/module.sh configure /tmp/lfw-wg-bad.json >/dev/null 2>&1; then
  echo 'FAIL accepted an invalid WireGuard IPv4 address' >&2; exit 1
fi
echo 'PASS WireGuard retains secrets on blank edit and rejects invalid tunnel CIDRs'
bash /usr/bin/wg-quick down wg0 >/dev/null 2>&1 || :
