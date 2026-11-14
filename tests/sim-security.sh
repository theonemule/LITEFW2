#!/bin/sh
# Native nftables GeoIP feed/rule tests with fake offline transport.
# Executes inside disposable Alpine after the generic packet-path fixture.
set -eu
cd /workspace
mkdir -p /tmp/lfw-sec-conf /tmp/lfw-fixture-bin
export LFW_MODULE_CONFIG_DIR=/tmp/lfw-sec-conf
export PATH="/tmp/lfw-fixture-bin:$PATH"

echo 'CASE geoip/atomic-update-and-kernel-block'
cat >/tmp/lfw-fixture-bin/curl <<'CURL'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    https://www.ipdeny.com/ipblocks/data/aggregated/us-aggregated.zone) :;;
    https://*) echo "Unexpected GeoIP HTTPS source: $arg" >&2; exit 1;;
  esac
done
cat <<'NETS'
192.0.2.2/32
10.1.0.0/16
10.2.0.0/16
10.3.0.0/16
10.4.0.0/16
10.5.0.0/16
10.6.0.0/16
10.7.0.0/16
10.8.0.0/16
10.9.0.0/16
10.10.0.0/16
10.11.0.0/16
NETS
CURL
chmod +x /tmp/lfw-fixture-bin/curl
printf '%s\n' '{"countries":["us"],"enabled":false}' >"$LFW_MODULE_CONFIG_DIR/geoip.json"
/workspace/modules/geoip/module.sh refresh > /tmp/lfw-geoip-result.json
jq -e '.loadedNetworks==12' /tmp/lfw-geoip-result.json >/dev/null
test -s "$LFW_MODULE_CONFIG_DIR/geoip.nft"
cat >/tmp/lfw-native-geoip.nft <<'NFT'
destroy table inet lfw_sim
table inet lfw_sim {
NFT
cat "$LFW_MODULE_CONFIG_DIR/geoip.nft" >> /tmp/lfw-native-geoip.nft
cat >>/tmp/lfw-native-geoip.nft <<'NFT'
 chain filter_forward { type filter hook forward priority filter; policy accept;
   ip saddr @litefw_geo4 drop comment "lfw:module:geoip"
 }
}
NFT
nft -c -f /tmp/lfw-native-geoip.nft
nft -f /tmp/lfw-native-geoip.nft
nft list set inet lfw_sim litefw_geo4 | grep -Fq '192.0.2.2'
test -z "$(/workspace/modules/geoip/module.sh firewall)"
jq '.enabled=true' "$LFW_MODULE_CONFIG_DIR/geoip.json" >/tmp/lfw-geoip-on.json
mv /tmp/lfw-geoip-on.json "$LFW_MODULE_CONFIG_DIR/geoip.json"
geo_rules=$(/workspace/modules/geoip/module.sh firewall)
printf '%s\n' "$geo_rules" | grep -Fq '@litefw_geo4' || {
  # Legacy descriptors are compiled by the nftables module translator.
  printf '%s\n' "$geo_rules" | grep -Fq 'litefw_geo4 src'
}
if ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null 2>&1; then
  echo 'FAIL native GeoIP block did not stop routed traffic' >&2; exit 1
fi
nft flush chain inet lfw_sim filter_forward
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
echo 'PASS GeoIP interval set enforces native nftables forwarding policy'

echo 'CASE geoip/bad-feed-preserves-existing-set'
checksum=$(sha256sum "$LFW_MODULE_CONFIG_DIR/geoip.nft" | cut -d' ' -f1)
cp /tmp/lfw-fixture-bin/curl /tmp/lfw-fixture-bin/curl.ok
printf '#!/bin/sh\nexit 22\n' >/tmp/lfw-fixture-bin/curl
chmod +x /tmp/lfw-fixture-bin/curl
if /workspace/modules/geoip/module.sh refresh >/dev/null 2>&1; then
  echo 'FAIL GeoIP download failure returned success' >&2; exit 1
fi
test "$checksum" = "$(sha256sum "$LFW_MODULE_CONFIG_DIR/geoip.nft" | cut -d' ' -f1)"
nft list set inet lfw_sim litefw_geo4 | grep -Fq '192.0.2.2'
mv /tmp/lfw-fixture-bin/curl.ok /tmp/lfw-fixture-bin/curl
echo 'PASS failed GeoIP refresh preserves previous feed and kernel set'

echo 'CASE cloudflared/protected-token-not-exposed'
printf '%s\n' '{"token":"test-only-very-long-cloudflared-token"}' >/tmp/lfw-cloudflare.json
/workspace/modules/cloudflared/module.sh configure /tmp/lfw-cloudflare.json > /tmp/lfw-cloudflare-state.json
test "$(stat -c %a /etc/cloudflared/litefw-token)" = 600
jq -e '.settings.credentialConfigured==true and .settings.token==null' /tmp/lfw-cloudflare-state.json >/dev/null
if grep -Fq 'test-only-very-long-cloudflared-token' /tmp/lfw-cloudflare-state.json; then
  echo 'FAIL token leaked in API snapshot' >&2; exit 1
fi
printf '%s\n' '{"token":""}' >/tmp/lfw-cloudflare-edit.json
/workspace/modules/cloudflared/module.sh configure /tmp/lfw-cloudflare-edit.json >/dev/null
grep -Fxq 'test-only-very-long-cloudflared-token' /etc/cloudflared/litefw-token
echo 'PASS Cloudflare token is root-only, masked and retained on blank edit'

echo 'CASE mdns-and-portal/refuse-WAN'
printf '%s\n' '{"interfaces":["eth0","lfw_in"]}' >/tmp/lfw-mdns-wan.json
if /workspace/modules/mdns/module.sh configure /tmp/lfw-mdns-wan.json >/dev/null 2>&1; then
  echo 'FAIL mDNS reflector allowed default WAN' >&2; exit 1
fi
printf '%s\n' '{"interfaces":["lfw_in","lfw_out"]}' >/tmp/lfw-mdns-lan.json
/workspace/modules/mdns/module.sh configure /tmp/lfw-mdns-lan.json >/dev/null
grep -Fxq 'allow-interfaces=lfw_in,lfw_out' /etc/avahi/avahi-daemon.conf
grep -Fxq 'enable-reflector=yes' /etc/avahi/avahi-daemon.conf
printf '%s\n' '{"interface":"eth0","gatewayName":"Guest Test"}' >/tmp/lfw-portal-wan.json
if /workspace/modules/captive/module.sh configure /tmp/lfw-portal-wan.json >/dev/null 2>&1; then
  echo 'FAIL captive portal accepted default WAN' >&2; exit 1
fi
printf '%s\n' '{"interface":"lfw_in","gatewayName":"Guest Test"}' >/tmp/lfw-portal-lan.json
/workspace/modules/captive/module.sh configure /tmp/lfw-portal-lan.json >/dev/null
grep -Fxq 'GatewayInterface lfw_in' /etc/opennds/opennds.conf
echo 'PASS reflector and guest portal refuse WAN interface'
