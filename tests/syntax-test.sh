#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
failed=0

check_file() {
  f=$1
  [ -f "$f" ] || return 0
  if ! sh -n "$f"; then
    echo "syntax failed: $f" >&2
    failed=1
  fi
}

check_file "$ROOT/install.sh"
for f in "$ROOT"/bin/* "$ROOT"/cgi/*.cgi "$ROOT"/lib/*.sh "$ROOT"/openrc/*; do
  check_file "$f"
done

if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/www/app.js"
fi
[ "$failed" -eq 0 ]
echo "syntax-test: PASS"
