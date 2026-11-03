#!/bin/sh
# Native ipset/iptables tests with fake offline feed transport and API sources.
# Executes inside the disposable Alpine container after the Suricata test.
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
ipset test litefw_geo4 192.0.2.2 >/dev/null
test -s "$LFW_MODULE_CONFIG_DIR/geoip.ipset"
test -z "$(/workspace/modules/geoip/module.sh firewall)"
jq '.enabled=true' "$LFW_MODULE_CONFIG_DIR/geoip.json" >/tmp/lfw-geoip-on.json
mv /tmp/lfw-geoip-on.json "$LFW_MODULE_CONFIG_DIR/geoip.json"
geo_rules=$(/workspace/modules/geoip/module.sh firewall)
printf '%s\n' "$geo_rules" | grep -Fq 'litefw_geo4 src'
iptables -F LFW_FWD
printf '%s\n' "$geo_rules" | grep '^-A LFW_FWD ' | while IFS= read -r line; do
  iptables $line
done
if ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null 2>&1; then
  echo 'FAIL GeoIP block did not stop simulated traffic' >&2; exit 1
fi
iptables -F LFW_FWD
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
echo 'PASS GeoIP country networks enforce real kernel filtering'

echo 'CASE geoip/bad-feed-keeps-previous-ipset'
cp /tmp/lfw-fixture-bin/curl /tmp/lfw-fixture-bin/curl.ok
printf '#!/bin/sh\nexit 22\n' >/tmp/lfw-fixture-bin/curl
chmod +x /tmp/lfw-fixture-bin/curl
if /workspace/modules/geoip/module.sh refresh >/dev/null 2>&1; then
  echo 'FAIL GeoIP download failure returned success' >&2; exit 1
fi
ipset test litefw_geo4 192.0.2.2 >/dev/null
mv /tmp/lfw-fixture-bin/curl.ok /tmp/lfw-fixture-bin/curl
echo 'PASS failed GeoIP refresh preserves previous bans'

echo 'CASE crowdsec/sync-decisions-to-kernel-block'
cat >/tmp/lfw-fixture-bin/cscli <<'CSCLI'
#!/bin/sh
[ "${SIM_CROWDSEC_FAIL:-0}" != 1 ] || exit 28
[ "$1" = decisions ] && [ "$2" = list ] || exit 1
cat <<'DECISIONS'
[
 {"type":"ban","scope":"Ip","value":"192.0.2.2"},
 {"type":"ban","scope":"Range","value":"10.77.0.0/16"},
 {"type":"ban","scope":"Ip","value":"NOT_AN_IP"},
 {"type":"captcha","scope":"Ip","value":"203.0.113.77"}
]
DECISIONS
CSCLI
chmod +x /tmp/lfw-fixture-bin/cscli
printf '%s\n' '{"enabled":true}' >"$LFW_MODULE_CONFIG_DIR/crowdsec.json"
/workspace/modules/shared/crowdsec-sync.sh >/tmp/lfw-cs-output.log
ipset test litefw_cs4 192.0.2.2 >/dev/null
ipset test litefw_cs4 10.77.5.6 >/dev/null
if ipset test litefw_cs4 203.0.113.77 >/dev/null 2>&1; then
  echo 'FAIL a non-ban decision entered the CrowdSec set' >&2; exit 1
fi
# Only the CrowdSec service-status response is mocked; the packet filter
# and all ipset operations are the real Linux kernel interfaces.
cat >/tmp/lfw-fixture-bin/rc-service <<'SVC'
#!/bin/sh
[ "$1" = crowdsec ] && [ "$2" = status ]
SVC
chmod +x /tmp/lfw-fixture-bin/rc-service
cs_rules=$(/workspace/modules/crowdsec/module.sh firewall)
printf '%s\n' "$cs_rules" | grep -Fq -- '-A LFW_FWD -m set --match-set litefw_cs4'
printf '%s\n' "$cs_rules" | grep '^-A LFW_FWD ' | while IFS= read -r line; do
  iptables $line
done
if ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null 2>&1; then
  echo 'FAIL CrowdSec ban did not stop simulated traffic' >&2; exit 1
fi
iptables -F LFW_FWD
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
echo 'PASS CrowdSec active bans enforce real kernel filtering'

echo 'CASE crowdsec/failed-LAPI-preserves-previous-blocks'
if SIM_CROWDSEC_FAIL=1 /workspace/modules/shared/crowdsec-sync.sh >/dev/null 2>&1; then
  echo 'FAIL simulated LAPI failure returned success' >&2; exit 1
fi
ipset test litefw_cs4 192.0.2.2 >/dev/null
echo 'PASS CrowdSec LAPI outage preserves earlier kernel bans'

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
