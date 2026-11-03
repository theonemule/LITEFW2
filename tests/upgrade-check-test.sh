#!/bin/sh
# Safe update-version interpretation; no network dependency.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf '2.2.7\n' >"$tmp/VERSION"
LFW_LIB=$tmp
RESULT=$tmp/result.json
export LFW_LIB RESULT
. ./lib/sys.sh
upgrade_newer 2.2.8 2.2.7 || exit 1
if upgrade_newer 2.2.7 2.2.8; then echo "FAIL: downgrade allowed"; exit 1; fi
if upgrade_newer 2.2.8 2.2.8; then echo "FAIL: equal version offered"; exit 1; fi
if upgrade_newer v2.2.8 2.2.7; then echo "FAIL: invalid version offered"; exit 1; fi
curl() { printf '{"tag_name":"v2.2.8"}\n'; }
op_upgrade_check
jq -e '.installed=="2.2.7" and .latest=="2.2.8" and .available==true' "$RESULT" >/dev/null
printf '2.2.8\n' >"$tmp/VERSION"
op_upgrade_check
jq -e '.installed=="2.2.8" and .available==false' "$RESULT" >/dev/null
grep -Fq 'POST:/system/updates/check)' cgi/api.cgi
grep -Fq 'POST:/system/updates/install)' cgi/api.cgi
grep -Fq 'POST:/system/updates/upload)' cgi/api.cgi
grep -Fq 'POST:/system/packages/check)' cgi/api.cgi
grep -Fq 'POST:/system/packages/upgrade)' cgi/api.cgi
grep -Fq "btn('Check packages'" www/app.js
grep -Fq "btn('Apply package updates'" www/app.js
grep -Fq '/app.js?v=2.2.14' www/index.html
grep -Fq "btn('Check for updates'" www/app.js
grep -Fq "btn('Install update'" www/app.js
grep -Fq "btn('Install uploaded file'" www/app.js
echo "PASS: latest version detection, upgrade UI actions, update API routes"
