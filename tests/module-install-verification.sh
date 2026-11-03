#!/bin/sh
# An installer returning zero must NOT imply an installed native service.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/modules/mock" "$tmp/bin"
cat >"$tmp/modules/manifest.json" <<'JSON'
{"schemaVersion":1,"modules":[{"id":"mock","version":"1","core":false,"packages":["mock-pkg"],"scripts":{"controller":"mock/module.sh","install":"mock/install.sh","remove":"mock/uninstall.sh"}}]}
JSON
cat >"$tmp/modules/mock/module.sh" <<'SH'
#!/bin/sh
case "$1" in
  installed) test -f "$(dirname "$0")/installed.flag";;
  meta) echo '{"id":"mock","name":"Mock"}';;
  *) exit 1;;
esac
SH
cat >"$tmp/modules/mock/install.sh" <<'SH'
#!/bin/sh
if [ "${FAKE_INSTALL_WORKS:-}" = 1 ]; then touch "$(dirname "$0")/installed.flag"; fi
exit 0
SH
cat >"$tmp/modules/mock/uninstall.sh" <<'SH'
#!/bin/sh
rm -f "$(dirname "$0")/installed.flag"
SH
cat >"$tmp/bin/apk" <<'SH'
#!/bin/sh
[ "$1" = info ] && [ "$2" = -e ]
SH
chmod +x "$tmp"/modules/mock/*.sh "$tmp/bin/apk"
export PATH="$tmp/bin:$PATH" LFW_LIB="$PWD/lib" BODY="$tmp/body" RESULT="$tmp/result" LFW_LOG="$tmp/litefw.log"
. ./lib/common.sh
. ./lib/modules.sh
LFW_MODULE_DIR="$tmp/modules"
printf '{"id":"mock"}' >"$BODY"
if (op_module_install) >"$tmp/out" 2>"$tmp/err"; then
  echo "FAIL: false success for missing module" >&2
  exit 1
fi
grep -q 'Installer exited but mock is not installed' "$tmp/err"
echo "PASS: installer exit 0 is rejected without native installation"
FAKE_INSTALL_WORKS=1
export FAKE_INSTALL_WORKS
op_module_install
jq -e '.installed == true' "$RESULT" >/dev/null
test -f "$tmp/modules/mock/installed.flag"
echo "PASS: verified install accepted"
op_module_remove
jq -e '.removed == true' "$RESULT" >/dev/null
test ! -f "$tmp/modules/mock/installed.flag"
echo "PASS: removal verified"
