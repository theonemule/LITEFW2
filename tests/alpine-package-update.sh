#!/bin/sh
# APK package reporting, confirmation and error handling without touching host packages.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat > "$tmp/installed.old" <<'DATA'
busybox-1.35.0-r1 x86_64 {busybox} (GPL) [installed]
inadyn-2.12.0-r0 x86_64 {inadyn} (GPL) [installed]
dnsmasq-2.92-r0 x86_64 {dnsmasq} (GPL) [installed]
DATA
cat > "$tmp/installed.new" <<'DATA'
busybox-1.36.0-r0 x86_64 {busybox} (GPL) [installed]
inadyn-2.13.0-r0 x86_64 {inadyn} (GPL) [installed]
dnsmasq-2.92-r0 x86_64 {dnsmasq} (GPL) [installed]
DATA
cat > "$tmp/candidates.old" <<'DATA'
busybox-1.36.0-r0 x86_64 {busybox} (GPL) [upgradable from: busybox-1.35.0-r1]
inadyn-2.13.0-r0 x86_64 {inadyn} (GPL) [upgradable from: inadyn-2.12.0-r0]
DATA
: > "$tmp/candidates.new"
printf '%s\n' 'https://dl-4.alpinelinux.org/alpine/v3.24/main' > "$tmp/repositories"
export TEST_TMP="$tmp" LFW_LIB="$tmp" RESULT="$tmp/result" BODY="$tmp/body" LFW_LOG="$tmp/log" LFW_APK_UPGRADE_LOG="$tmp/apk-upgrade.log"
cp "$tmp/repositories" "$tmp/repositories-copy"
# No external APK commands are invoked.
apk() {
  case "$*" in
    '--timeout 12 update') [ ! -f "$TEST_TMP/fail" ];;
    'list --installed') cat "$TEST_TMP/installed.$(cat "$TEST_TMP/phase")";;
    'list --upgradable') cat "$TEST_TMP/candidates.$(cat "$TEST_TMP/phase")";;
    '--timeout 12 upgrade') printf 'new\n' > "$TEST_TMP/phase";;
    *) echo "Unexpected apk invocation: $*" >&2; return 1;;
  esac
}
# Redirect the repository path only in this test: replace function for fixture.
. ./lib/common.sh
. ./lib/sys.sh
packages_repositories() { _repositories=$(cat "$TEST_TMP/repositories"); }
echo old > "$tmp/phase"
printf '{"confirmed":false}\n' > "$BODY"
if (op_packages_upgrade) >/dev/null 2>&1; then
  echo "FAIL: package upgrade accepted without confirmation" >&2; exit 1
fi
test "$(cat "$tmp/phase")" = old
op_packages_check
jq -e '.installedCount==3 and .upgradableCount==2 and .currentCount==1 and
  .upgradable[0].name=="busybox" and .upgradable[0].installedVersion=="1.35.0-r1" and
  .upgradable[0].availableVersion=="1.36.0-r0" and
  .current[0].name=="dnsmasq" and (.repositories|length)==1' "$RESULT" >/dev/null
printf '{"confirmed":true}\n' > "$BODY"
op_packages_upgrade
jq -e '.upgradedCount==2 and .rebootSuggested==true and .remainingCount==0 and
  any(.upgraded[]; .name=="inadyn" and .previousVersion=="2.12.0-r0" and .installedVersion=="2.13.0-r0")' "$RESULT" >/dev/null
op_packages_check
jq -e '.upgradableCount==0 and .currentCount==3' "$RESULT" >/dev/null
printf '%s\n' 'PASS: package inventory, explicit confirmation, upgrades, current-state verification, reboot advisory'
