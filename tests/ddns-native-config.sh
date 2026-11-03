#!/bin/sh
# Native, unmarked inadyn files are not LiteFW configuration. No package or
# running service changes are performed by this test.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export LFW_INADYN_CONF="$tmp/inadyn.conf"
mod=modules/ddns/module.sh
"$mod" snapshot | jq -e '.configured==false and .nativeConfig==false' >/dev/null
cat >"$LFW_INADYN_CONF" <<'NATIVE'
# Alpine packaged example, not a LiteFW managed config
period = 300
NATIVE
"$mod" snapshot | jq -e '.configured==false and .nativeConfig==true' >/dev/null
cat >"$LFW_INADYN_CONF" <<'MANAGED'
# litefwm:provider=default@duckdns.org
# litefwm:hosts=host.example.net
# litefwm:username=account
# litefwm:period=300
# litefwm:interface=eth2
# litefwm:custom-ssl=true
password = "not-an-actual-credential"
MANAGED
"$mod" snapshot | jq -e '.configured==true and .provider=="default@duckdns.org" and
  .hostnames==["host.example.net"] and .period==300 and .credentialConfigured==true' >/dev/null
printf 'PASS: missing, native sample, and LiteFW-managed inadyn configuration states\n'
