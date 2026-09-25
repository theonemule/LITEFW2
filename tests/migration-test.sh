#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
export LITEFWM_ETC="$TMP/etc"
export LITEFWM_STATE="$TMP/state"
export LITEFWM_RUN="$TMP/run"
export LITEFWM_LOG="$TMP/log"
export LITEFWM_GENERATED="$TMP/state/generated"
mkdir -p "$LITEFWM_STATE"

for legacy in legacy-v1.json legacy-v2.json; do
  out="$TMP/$legacy.v3"
  "$ROOT/bin/configctl" migrate "$ROOT/tests/fixtures/$legacy" > "$out"
  "$ROOT/bin/configctl" validate "$out" >/dev/null
  jq -e '.version==3 and .management.port==5187 and .management.sshPort==22 and .management.allowSsh==true' "$out" >/dev/null
done

v1="$TMP/legacy-v1.json.v3"
jq -e '.interfaces[] | select(.id=="lan") | .type=="bridge" and .device=="br0" and .vlanAware==true and (.members|sort)==["eth1","eth2"]' "$v1" >/dev/null
jq -e '.interfaces[] | select(.id=="eth1") | .type=="physical" and .device=="eth1"' "$v1" >/dev/null
jq -e '.interfaces[] | select(.id=="iot") | .type=="vlan" and .parent=="lan" and .device=="br0.20" and .vlanId==20' "$v1" >/dev/null
jq -e '.segments[] | select(.id=="iot") | .interface=="iot" and .zone=="internal" and .addressMode=="static"' "$v1" >/dev/null

v2="$TMP/legacy-v2.json.v3"
jq -e '.segments[] | select(.id=="wan") | .zone=="external" and .addressMode=="static"' "$v2" >/dev/null
jq -e '.segments[] | select(.id=="lan") | .zone=="internal" and .addressMode=="static" and (.dhcp.ntp|type=="array")' "$v2" >/dev/null
jq -e '.firewall.nat.masquerade[0] | has("sourceSegment")' "$v2" >/dev/null

echo "migration-test: PASS"
