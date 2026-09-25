#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

grep -Fq '/etc/ddclient/ddclient.conf' "$ROOT/bin/ddnsctl"
if grep -Eq 'DDNS_CONFIG|config\.json' "$ROOT/bin/ddnsctl"; then
  echo "DDNS still uses a LiteFWM JSON config" >&2
  exit 1
fi

echo "ddns-render-test: PASS"
