#!/bin/sh
# Source-only contract and validation tests. Never touches live interfaces,
# OpenRC services, firewall rules, routing or /etc.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
new='suricata geoip crowdsec wireguard cloudflared multiwan mdns captive frr'
test "$(jq '.modules | length' modules/manifest.json)" -eq 14
for m in $new; do
  for f in module install uninstall; do test -x "modules/$m/$f.sh"; sh -n "modules/$m/$f.sh"; done
  modules/"$m"/module.sh meta | jq -e --arg id "$m" '.id == $id and (.name|length>0)' >/dev/null
done
sh -n modules/shared/controller.sh
sh -n lib/telemetry.sh
sh -n lib/telemetry-cron.sh
for f in modules/shared/init-* modules/shared/multiwan-check.sh; do sh -n "$f"; done
node --check www/app.js
node --check www/addons.js
for fixture in \
  'suricata|{"interface":"eth1","mode":"ids"}' \
  'geoip|{"countries":["us","ca"],"enabled":false}' \
  'crowdsec|{"enabled":true}' \
  'wireguard|{"interface":"wg0","address":"10.100.0.1/24","listenPort":51820,"peers":[{"publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","allowedIPs":"10.100.0.2/32"}]}' \
  'cloudflared|{"token":"abcdefghijklmnopqrstuv"}' \
  'multiwan|{"uplinks":[{"interface":"eth0","gateway":"192.0.2.1","priority":10},{"interface":"eth2","gateway":"192.0.2.2","priority":20}],"enabled":false}' \
  'mdns|{"interfaces":["eth1","eth2"]}' \
  'captive|{"interface":"eth2","gatewayName":"LiteFW Guest"}' \
  'frr|{"asn":64512,"routerId":"10.0.0.1","neighbors":[{"address":"192.0.2.2","remoteAs":64513}],"networks":["10.1.0.0/24"]}'
do
  m=${fixture%%|*}; json=${fixture#*|}
  printf '%s\n' "$json" >"$tmp/valid.json"
  modules/"$m"/module.sh validate "$tmp/valid.json" >/dev/null ||
    { echo "FAIL: validation rejected valid $m fixture" >&2; exit 1; }
  echo "PASS: $m metadata and configuration validation"
done
printf '{"interface":"wg0","address":"10.1.1.1/24","listenPort":51820,"peers":[{"publicKey":"BAD","allowedIPs":"0.0.0.0/0"}]}' >"$tmp/bad.json"
! modules/wireguard/module.sh validate "$tmp/bad.json" >/dev/null 2>&1
printf '{"countries":["United States"],"enabled":true}' >"$tmp/bad.json"
! modules/geoip/module.sh validate "$tmp/bad.json" >/dev/null 2>&1
printf '{"interface":"eth1","gatewayName":"hi\nGatewayInterface eth0"}' >"$tmp/bad.json"
! modules/captive/module.sh validate "$tmp/bad.json" >/dev/null 2>&1
# Telemetry's source data must be machine-parseable without any external service.
LFW_LIB="$PWD/lib" sh -c '. "$LFW_LIB/common.sh"; . "$LFW_LIB/telemetry.sh"; telemetry_otlp' |
  jq -e '.resourceMetrics[0].scopeMetrics[0].metrics | length==2' >/dev/null
printf '{"prometheus":true,"otlpEnabled":false}' >"$tmp/telemetry.json"
LFW_TELEM_CONF="$tmp/telemetry.json" LFW_LIB="$PWD/lib" sh -c '
 . "$LFW_LIB/common.sh"; . "$LFW_LIB/telemetry.sh"; telemetry_metrics' >"$tmp/metrics.txt"
grep -q '^litefw_uptime_seconds ' "$tmp/metrics.txt"
grep -q '^litefw_load1 ' "$tmp/metrics.txt"
# Each module must have UI routing and a native operation controller.
for m in $new; do
  grep -q "^op_${m}_configure()" lib/modules.sh
  grep -q "^op_${m}_service()" lib/modules.sh
done
grep -q 'module_firewall_snat_rules' lib/fw.sh
grep -q 'POST:/system/telemetry' cgi/api.cgi
grep -q 'GET:/telemetry/metrics' cgi/api.cgi
echo "PASS: nine add-on contracts, telemetry exporters, UI routing and safety input checks"
