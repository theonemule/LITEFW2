#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
failed=0
for f in "$ROOT"/install.sh "$ROOT"/bin/* "$ROOT"/cgi/*.cgi "$ROOT"/lib/*.sh "$ROOT"/openrc/*; do
  if ! sh -n "$f"; then
    echo "syntax failed: $f" >&2
    failed=1
  fi
done
if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/www/app.js"
fi
[ "$failed" -eq 0 ]
echo "syntax-test: PASS"
