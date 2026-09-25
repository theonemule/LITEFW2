#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

export LITEFWM_ETC="$TMP/etc"
export LITEFWM_CONFIG="$TMP/config.json"
"$ROOT/bin/configctl" migrate "$ROOT/tests/fixtures/legacy-v1.json" > "$LITEFWM_CONFIG"
export LITEFWM_STATE="$TMP/state"
export LITEFWM_RUN="$TMP/run"
export LITEFWM_LOG="$TMP/log"
export LITEFWM_GENERATED="$TMP/state/generated"
mkdir -p "$LITEFWM_STATE"

"$ROOT/bin/configctl" validate >/dev/null

jq -e '.version==2 and .management.port==5187 and .management.sshPort==22 and .management.allowSsh==true' "$LITEFWM_CONFIG" >/dev/null
jq -e '.interfaces[] | select(.id=="lan") | .type=="bridge" and .device=="br0" and .vlanAware==true and (.members|sort)==["eth1","eth2"]' "$LITEFWM_CONFIG" >/dev/null
jq -e '.interfaces[] | select(.id=="eth1") | .type=="physical" and .device=="eth1"' "$LITEFWM_CONFIG" >/dev/null
jq -e '.interfaces[] | select(.id=="eth2") | .type=="physical" and .device=="eth2"' "$LITEFWM_CONFIG" >/dev/null
jq -e '.interfaces[] | select(.id=="iot") | .type=="vlan" and .parent=="lan" and .device=="br0.20" and .vlanId==20' "$LITEFWM_CONFIG" >/dev/null
jq -e '.segments[] | select(.id=="iot") | .interface=="iot"' "$LITEFWM_CONFIG" >/dev/null

echo "migration-test: PASS"
