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
chmod 755 "$tmp/bin/curl" "$tmp/bin/id"
export PATH="$tmp/bin:$PATH"
export LFW_CF_LEGACY_CONF="$tmp/config.json" LFW_CF_LEGACY_STATE="$tmp/state.json"
export MOCK_CALLS="$tmp/patches"
script=modules/ddns/cloudflare-legacy.sh
"$script" status | jq -e '.configured and .zone=="example.net" and
    (.hostnames|length)==2 and (.apiKey==null) and (.email==null)' >/dev/null
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
echo 'PASS: credential-free status, check never writes, update succeeds, CNAME edits rejected'
