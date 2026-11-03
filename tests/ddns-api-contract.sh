#!/bin/sh
# lfwctl intentionally uses set -u, not -e. Validate propagation of every
# Cloudflare handler failure through the module operations layer.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export LFW_LIB="$PWD/lib" LFW_LOG="$tmp/litefw.log" BODY="$tmp/body.json" RESULT="$tmp/result.json"
printf '{}\n' >"$BODY"
. ./lib/common.sh
. ./lib/modules.sh
module_call() { echo 'Simulated Cloudflare API validation failure' >&2; return 12; }
for op in op_ddns_cfconfigure op_ddns_cfcheck op_ddns_cfupdate; do
  if ($op) >"$tmp/out" 2>"$tmp/err"; then
    echo "FAIL: $op reported success after module_call error" >&2
    exit 1
  fi
  grep -Eq 'Cloudflare.*(failed|failure)' "$tmp/err"
done
module_call() {
  case "$2" in
    cloudflare-configure) printf '{"zone":"example.net","credentialConfigured":true}\n';;
    cloudflare-check) printf '0 mismatched';;
    cloudflare-update) printf '2 refreshed';;
    *) return 1;;
  esac
}
op_ddns_cfconfigure
jq -e '.zone=="example.net" and .credentialConfigured==true' "$RESULT" >/dev/null
op_ddns_cfcheck
jq -e '.output=="0 mismatched"' "$RESULT" >/dev/null
op_ddns_cfupdate
jq -e '.output=="2 refreshed"' "$RESULT" >/dev/null
echo 'PASS: Cloudflare API failures cannot masquerade as successful operations'
