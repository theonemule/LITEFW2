#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
bad="$TMP/bad.json"
jq '.segments[0].interface="eth0; touch /tmp/pwned"' "$ROOT/tests/fixtures/full.json" > "$bad"
if LITEFWM_CONFIG="$bad" "$ROOT/bin/configctl" validate "$bad" >/dev/null 2>&1; then
  echo "unsafe interface value was accepted" >&2
  exit 1
fi
jq '.firewall.rules[0].destinationPort="443\n-A INPUT -j ACCEPT"' "$ROOT/tests/fixtures/full.json" > "$bad"
if LITEFWM_CONFIG="$bad" "$ROOT/bin/configctl" validate "$bad" >/dev/null 2>&1; then
  echo "unsafe firewall value was accepted" >&2
  exit 1
fi
echo "security-validation-test: PASS"
