#!/bin/sh
set -eu
cd /workspace
apk add --no-cache jq openvpn openvpn-openrc strongswan strongswan-openrc openssl >/dev/null
mkdir -p /etc/openvpn /etc/openvpn/pki/issued /etc/swanctl/conf.d
# A realistic self-signed fixture: private keys never leave this disposable container.
openssl req -x509 -newkey rsa:2048 -keyout /tmp/client.key -out /tmp/client.crt -nodes \
  -days 1 -subj /CN=vpn-test >/dev/null 2>&1
openvpn --genkey secret /tmp/ta.key >/dev/null 2>&1
{
  echo 'client'
  echo 'proto udp'
  echo 'remote vpn.example.net 1194'
  echo 'dev tun'
  echo 'nobind'
  echo 'persist-key'
  echo 'persist-tun'
  echo 'remote-cert-tls server'
  echo '<ca>'; cat /tmp/client.crt; echo '</ca>'
  echo '<cert>'; cat /tmp/client.crt; echo '</cert>'
  echo '<key>'; cat /tmp/client.key; echo '</key>'
  echo '<tls-crypt>'; cat /tmp/ta.key; echo '</tls-crypt>'
} >/tmp/client.ovpn
jq -n --rawfile profile /tmp/client.ovpn \
  '{id:"office",mode:"point-to-site",interface:"tun2",localSubnet:"",remoteSubnet:"",profile:$profile}' \
  >/tmp/client-request.json
modules/openvpn/instances.sh save /tmp/client-request.json | jq -e '.saved and .started==false' >/dev/null
test -f /etc/openvpn/lfwc-office.conf
test -L /etc/init.d/openvpn.lfwc-office
test "$(stat -c %a /etc/openvpn/lfwc-office.conf)" = 600
grep -Fq 'dev tun2' /etc/openvpn/lfwc-office.conf
grep -Fq 'pull-filter ignore "redirect-gateway"' /etc/openvpn/lfwc-office.conf
modules/openvpn/instances.sh list | jq -e 'length==1 and .[0].mode=="point-to-site" and .[0].interface=="tun2"' >/dev/null
# Reconfiguration with the same protected profile, site-to-site subnet routing.
jq -n '{id:"office",mode:"site-to-site",interface:"tun2",localSubnet:"10.1.0.0/24",
 remoteSubnet:"10.66.0.0/24",profile:""}' >/tmp/client-request.json
modules/openvpn/instances.sh save /tmp/client-request.json | jq -e '.saved' >/dev/null
grep -Fq 'route-nopull' /etc/openvpn/lfwc-office.conf
grep -Fq 'route 10.66.0.0 255.255.255.0' /etc/openvpn/lfwc-office.conf
modules/openvpn/instances.sh list | jq -e '.[0].mode=="site-to-site" and .[0].localSubnet=="10.1.0.0/24"' >/dev/null
# Dangerous script-execution options are explicitly rejected.
jq -n --rawfile profile /tmp/client.ovpn '{id:"evil",mode:"point-to-site",interface:"tun3",
 localSubnet:"",remoteSubnet:"",profile:($profile+"\nscript-security 2\nup /tmp/evil.sh\n")}' >/tmp/client-request.json
if modules/openvpn/instances.sh save /tmp/client-request.json >/dev/null 2>&1; then
  echo 'FAIL: script hook accepted in imported OpenVPN profile' >&2; exit 1
fi
test ! -e /etc/openvpn/lfwc-evil.conf
# Create server-side site peer CCD routing; no OpenVPN server restarted.
printf '# OpenVPN server fixture\nport 1194\nproto udp\n' >/etc/openvpn/litefwm.conf
cp /tmp/client.crt /etc/openvpn/pki/issued/branch.crt
jq -n '{id:"branch",localSubnet:"10.1.0.0/24",remoteSubnet:"10.88.0.0/24"}' >/tmp/site-request.json
modules/openvpn/site-peers.sh save /tmp/site-request.json | jq -e '.restartRequired' >/dev/null
grep -Fq 'iroute 10.88.0.0 255.255.255.0' /etc/openvpn/ccd/branch
grep -Fq 'route 10.88.0.0 255.255.255.0' /etc/openvpn/litefwm.conf
grep -Fq 'client-config-dir /etc/openvpn/ccd' /etc/openvpn/litefwm.conf
modules/openvpn/site-peers.sh list | jq -e 'length==1 and .[0].remoteSubnet=="10.88.0.0/24"' >/dev/null
modules/openvpn/site-peers.sh save /tmp/site-request.json >/dev/null
test "$(grep -c '^route 10.88.0.0' /etc/openvpn/litefwm.conf)" = 1
test "$(modules/openvpn/site-peers.sh list | jq length)" = 1
echo 'PASS OpenVPN: independent point/site client configs and server CCD routing; script injection blocked'
# IPsec IKEv2 with safe disabled-by-default configuration.
jq -n '{id:"branch",peer:"198.51.100.24",localSubnet:"10.1.0.0/24",
 remoteSubnet:"10.44.0.0/24",localId:"fw.example.net",remoteId:"branch.example.net",
 psk:"THIS_IS_A_TEST_RANDOM_SECRET_123456",enabled:false}' >/tmp/ipsec.json
modules/ipsec/module.sh tunnel-save /tmp/ipsec.json >/tmp/saved.json
jq -e '.started==false' /tmp/saved.json >/dev/null
test -f /etc/swanctl/conf.d/litefwm-branch.disabled
test ! -e /etc/swanctl/conf.d/litefwm-branch.conf
modules/ipsec/module.sh snapshot | jq -e '.tunnels|length==1 and .[0].enabled==false and .[0].psk==null' >/dev/null
# Enabled profiles appear in native swanctl conf.d and must load with real charon.
jq '.enabled=true|.psk=""' /tmp/ipsec.json >/tmp/enable.json
modules/ipsec/module.sh tunnel-save /tmp/enable.json >/tmp/saved.json
test -f /etc/swanctl/conf.d/litefwm-branch.conf
test ! -e /etc/swanctl/conf.d/litefwm-branch.disabled
test "$(stat -c %a /etc/swanctl/conf.d/litefwm-branch.conf)" = 600
/usr/lib/strongswan/charon >/tmp/charon.log 2>&1 &
pid=$!
sleep 1
swanctl --load-conns | grep -Fq "loaded connection 'litefwm-branch'"
swanctl --load-creds | grep -Fq "loaded ike secret 'ike-litefwm-branch'"
swanctl --list-conns | grep -Fq '10.44.0.0/24'
# No network tunnel is initiated; simulate invalid profile update.
jq '.localSubnet="invalid"' /tmp/ipsec.json >/tmp/bad.json
if modules/ipsec/module.sh tunnel-save /tmp/bad.json >/dev/null 2>&1; then
  echo 'FAIL: invalid IPsec traffic selector accepted' >&2; exit 1
fi
test -f /etc/swanctl/conf.d/litefwm-branch.conf
kill "$pid" || :
echo 'PASS IPsec: native strongSwan syntax, disabled-by-default, secret retention and input validation'
