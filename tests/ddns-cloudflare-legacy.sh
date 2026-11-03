#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
cat > "$tmp/config.json" <<'DATA'
{"zone":"example.net","email":"example@example.net","apiKey":"THIS_IS_A_TEST_KEY_NOT_REAL_12345678","hostnames":["cloud.example.net","home.example.net"]}
DATA
cat > "$tmp/bin/curl" <<'MOCK'
#!/bin/sh
case "$*" in
  *api.ipify.org*) printf '198.51.100.123';;
  *'zones?name='*) printf '%s\n' '{"success":true,"result":[{"id":"zone123"}]}';;
  *'--request PATCH'*)
    printf 'patch\n' >>"$MOCK_CALLS"
    printf '%s\n' '{"success":true,"result":{"type":"A","content":"198.51.100.123"}}';;
  *'dns_records?name='*)
    case "$*" in
      *cloud.example.net*) host=cloud.example.net;;
      *home.example.net*) host=home.example.net;;
      *) exit 2;;
    esac
    case "${MOCK_CNAME:-0}" in 1) type=CNAME;; *) type=A;; esac
    printf '{"success":true,"result":[{"id":"record123","name":"%s","type":"%s","content":"203.0.113.123"}]}\n' "$host" "$type";;
  *) echo 'Unexpected API request' >&2; exit 2;;
esac
MOCK
cat > "$tmp/bin/id" <<'ID'
#!/bin/sh
if [ "$1" = -u ]; then printf '0\n'; else /usr/bin/id "$@"; fi
ID
cat > "$tmp/bin/rc-service" <<'RC'
#!/bin/sh
exit 0
RC
cat > "$tmp/bin/rc-update" <<'RC'
#!/bin/sh
exit 0
RC
chmod 755 "$tmp/bin/curl" "$tmp/bin/id" "$tmp/bin/rc-service" "$tmp/bin/rc-update"
export PATH="$tmp/bin:$PATH"
export LFW_CF_LEGACY_CONF="$tmp/config.json" LFW_CF_LEGACY_STATE="$tmp/state.json"
export MOCK_CALLS="$tmp/patches"
export LFW_CF_CRON_FILE="$tmp/root-crontab" LFW_CF_PERIODIC_FILE="$tmp/old-periodic"
printf '1 * * * * echo preserve-me\n' >"$LFW_CF_CRON_FILE"
printf 'old-periodic\n' >"$LFW_CF_PERIODIC_FILE"
script=modules/ddns/cloudflare-legacy.sh
"$script" status | jq -e '.configured and .zone=="example.net" and
    (.hostnames|length)==2 and (.apiKey==null) and (.email=="example@example.net")' >/dev/null
"$script" check >/dev/null
jq -e '.updated==0 and .mismatched==2 and .unchanged==0' "$LFW_CF_LEGACY_STATE" >/dev/null
test ! -e "$MOCK_CALLS"
"$script" sync >/dev/null
jq -e '.updated==2 and .mismatched==0' "$LFW_CF_LEGACY_STATE" >/dev/null
test "$(wc -l < "$MOCK_CALLS")" = 2
MOCK_CNAME=1
export MOCK_CNAME
if "$script" force >/dev/null 2>&1; then
  echo 'FAIL: CNAME wrongly treated as an A record'; exit 1
fi
test "$(wc -l < "$MOCK_CALLS")" = 2
# Admin editing must preserve the protected key if the field is blank.
cat >"$tmp/request.json" <<'REQUEST'
{"zone":"example.net","email":"example@example.net","apiKey":"","hostnames":["cloud.example.net","home.example.net"],"scheduleMinutes":30,"enabled":true}
REQUEST
MOCK_CNAME=0
export MOCK_CNAME
modules/ddns/cloudflare-configure.sh "$tmp/request.json" >"$tmp/response.json"
jq -e '.scheduleMinutes==30 and .enabled==true and .credentialConfigured==true and (.apiKey==null)' "$tmp/response.json" >/dev/null
jq -e '.apiKey=="THIS_IS_A_TEST_KEY_NOT_REAL_12345678" and .scheduleMinutes==30' "$tmp/config.json" >/dev/null
grep -Fq '*/30 * * * *' "$LFW_CF_CRON_FILE"
grep -Fq 'preserve-me' "$LFW_CF_CRON_FILE"
test ! -e "$LFW_CF_PERIODIC_FILE"
# Disable and re-enable schedule without touching unrelated cron jobs.
jq '.enabled=false|.scheduleMinutes=60' "$tmp/request.json" >"$tmp/disable.json"
modules/ddns/cloudflare-configure.sh "$tmp/disable.json" >"$tmp/response.json"
test "$(grep -c 'litefw-cloudflare-managed' "$LFW_CF_CRON_FILE" || :)" = 0
grep -Fq 'preserve-me' "$LFW_CF_CRON_FILE"
# Reject a changed profile if any selected record is actually a CNAME.
MOCK_CNAME=1
export MOCK_CNAME
cp "$tmp/config.json" "$tmp/saved.json"
if modules/ddns/cloudflare-configure.sh "$tmp/request.json" >/dev/null 2>&1; then
  echo 'FAIL: CNAME accepted in Cloudflare settings editor' >&2; exit 1
fi
cmp "$tmp/config.json" "$tmp/saved.json"
test "$(grep -c 'litefw-cloudflare-managed' "$LFW_CF_CRON_FILE" || :)" = 0
# Invalid record host and unsupported schedule also leave the file unchanged.
MOCK_CNAME=0
export MOCK_CNAME
jq '.hostnames=["ollama.otherzone.net"]' "$tmp/request.json" >"$tmp/bad.json"
if modules/ddns/cloudflare-configure.sh "$tmp/bad.json" >/dev/null 2>&1; then
  echo 'FAIL: out-of-zone hostname accepted' >&2; exit 1
fi
cmp "$tmp/config.json" "$tmp/saved.json"
jq '.scheduleMinutes=7' "$tmp/request.json" >"$tmp/bad.json"
if modules/ddns/cloudflare-configure.sh "$tmp/bad.json" >/dev/null 2>&1; then
  echo 'FAIL: arbitrary schedule accepted' >&2; exit 1
fi
cmp "$tmp/config.json" "$tmp/saved.json"
echo 'PASS: protected Cloudflare edit, cron scheduling and disable, rollback on invalid records'
