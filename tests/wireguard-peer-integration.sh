#!/bin/sh
set -eu
cd /workspace
apk add --no-cache bash jq python3 wireguard-tools iproute2 >/dev/null
mkdir -p /tmp/lfw-wg-conf
export LFW_MODULE_CONFIG_DIR=/tmp/lfw-wg-conf
jq -n '{interface:"wg0",address:"10.240.0.1/24",listenPort:51820,
  serverEndpoint:"vpn.example.net",dns:"10.240.0.1",peers:[],privateKey:""}' >/tmp/wg-setup.json
modules/wireguard/module.sh configure /tmp/wg-setup.json >/tmp/wg-state.json
jq -e '.settings.credentialConfigured and .settings.privateKey==null' /tmp/wg-state.json >/dev/null
test "$(stat -c %a /etc/wireguard/wg0.conf)" = 600
test "$(stat -c %a /tmp/lfw-wg-conf/wireguard.json)" = 600
grep -q '^PrivateKey = ' /etc/wireguard/wg0.conf
server_key=$(sed -n 's/^PrivateKey = //p' /etc/wireguard/wg0.conf)
echo 'PASS WireGuard initial setup auto-generates root-only server key'
jq -n '{id:"laptop",allowedIPs:"10.240.0.2/32",publicKey:"",
  endpoint:"",persistentKeepalive:25,enabled:true}' >/tmp/wg-peer.json
python3 modules/shared/wireguard-peers.py peerset /tmp/wg-peer.json | jq -e '.generatedClientKey==true' >/dev/null
test "$(stat -c %a /tmp/lfw-wg-conf/wg-clients/laptop.key)" = 600
python3 modules/shared/wireguard-peers.py list | jq -e '.peers[0].hasClientProfile==true' >/dev/null
modules/wireguard/module.sh snapshot | jq -e '.settings.privateKey==null and .settings.peers[0].hasClientProfile==true' >/dev/null
grep -Fq 'AllowedIPs = 10.240.0.2/32' /etc/wireguard/wg0.conf
echo 'PASS peer generated through validated native config and secret stays private'
jq -n '{id:"laptop"}' >/tmp/wg-profile.json
python3 modules/shared/wireguard-peers.py clientprofile /tmp/wg-profile.json |
 jq -e '.filename=="laptop.conf" and (.profile|contains("Endpoint = vpn.example.net:51820")) and (.profile|contains("10.240.0.2/32"))' >/dev/null
echo 'PASS authenticated client profile contains matching endpoint and tunnel address'
jq -n '{id:"laptop",enabled:false}' >/tmp/wg-disable.json
python3 modules/shared/wireguard-peers.py peerenable /tmp/wg-disable.json | jq -e '.enabled==false' >/dev/null
if grep -Fq 'AllowedIPs = 10.240.0.2/32' /etc/wireguard/wg0.conf; then
 echo 'FAIL disabled peer is still present in live native config' >&2; exit 1
fi
jq -n '{id:"laptop",enabled:true}' >/tmp/wg-enable.json
python3 modules/shared/wireguard-peers.py peerenable /tmp/wg-enable.json | jq -e '.enabled==true' >/dev/null
grep -Fq 'AllowedIPs = 10.240.0.2/32' /etc/wireguard/wg0.conf
test "$server_key" = "$(sed -n 's/^PrivateKey = //p' /etc/wireguard/wg0.conf)"
echo 'PASS peer enable/disable changes native config without regenerating server identity'
jq -n '{id:"laptop"}' >/tmp/wg-remove.json
python3 modules/shared/wireguard-peers.py peerremove /tmp/wg-remove.json | jq -e '.removed==true' >/dev/null
test ! -e /tmp/lfw-wg-conf/wg-clients/laptop.key
python3 modules/shared/wireguard-peers.py list | jq -e '.peers|length==0' >/dev/null
echo 'PASS peer removal cleans generated client private key'
