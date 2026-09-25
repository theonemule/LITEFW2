#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

[ ! -e "$ROOT/etc/config.json" ]
[ ! -e "$ROOT/etc/litefwm.conf" ]

if grep -RqsE 'LITEFWM_CONFIG|LITEFWM_STATE' "$ROOT/bin" "$ROOT/cgi" "$ROOT/lib" "$ROOT/openrc"; then
  echo "runtime still references LiteFWM JSON/state configuration" >&2
  exit 1
fi

if grep -q 'Apply changes' "$ROOT/www/index.html" "$ROOT/www/app.js"; then
  echo "staged Apply workflow still exists" >&2
  exit 1
fi

grep -Fq '/etc/litefwm/config.json' "$ROOT/install.sh"
grep -Fq 'Live system state' "$ROOT/www/index.html"

echo "migration-test: PASS"
