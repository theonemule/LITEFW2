#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

export LITEFWM_ETC="$TMP/etc"
export LITEFWM_CONFIG="$ROOT/tests/fixtures/full.json"
export LITEFWM_STATE="$TMP/state"
export LITEFWM_RUN="$TMP/run"
export LITEFWM_LOG="$TMP/log"
export LITEFWM_GENERATED="$TMP/state/generated"
export LITEFWM_DDNS_DIR="$TMP/etc/modules/ddns"
export LITEFWM_DDNS_CONFIG="$TMP/etc/modules/ddns/config.json"
export LITEFWM_DDCLIENT_CONFIG="$TMP/etc/ddclient/ddclient.conf"

mkdir -p "$LITEFWM_DDNS_DIR"
cat > "$LITEFWM_DDNS_CONFIG" <<'JSON'
{
  "enabled": true,
  "provider": "cloudflare",
  "interval": 300,
  "source": "web",
  "interface": "",
  "zone": "example.com",
  "server": "",
  "login": "",
  "password": "token-value",
  "hostnames": ["home.example.com", "vpn.example.com"]
}
JSON
chmod 0600 "$LITEFWM_DDNS_CONFIG"

"$ROOT/bin/ddnsctl" validate "$LITEFWM_DDNS_CONFIG" >/dev/null
out=$("$ROOT/bin/ddnsctl" render)

grep -Fq 'daemon=300' "$out"
grep -Fq 'usev4=webv4, webv4=ipify-ipv4' "$out"
grep -Fq 'protocol=cloudflare' "$out"
grep -Fq 'zone="example.com"' "$out"
grep -Fq 'password="token-value"' "$out"
grep -Fq 'home.example.com,vpn.example.com' "$out"

shown=$("$ROOT/bin/ddnsctl" show)
printf '%s' "$shown" | jq -e '.password=="" and .passwordSet==true' >/dev/null
if printf '%s' "$shown" | grep -Fq 'token-value'; then
  echo "DDNS secret leaked from show" >&2
  exit 1
fi

cat > "$TMP/interface.json" <<'JSON'
{
  "enabled": true,
  "provider": "noip",
  "interval": 600,
  "source": "interface",
  "interface": "eth0",
  "zone": "",
  "server": "",
  "login": "user@example.com",
  "password": "secret",
  "hostnames": ["home.ddns.net"]
}
JSON
"$ROOT/bin/ddnsctl" validate "$TMP/interface.json" >/dev/null
cp "$TMP/interface.json" "$LITEFWM_DDNS_CONFIG"
out=$("$ROOT/bin/ddnsctl" render)
grep -Fq 'usev4=ifv4, ifv4=eth0' "$out"
grep -Fq 'protocol=noip' "$out"
grep -Fq 'server=dynupdate.no-ip.com' "$out"

cat > "$TMP/bad.json" <<'JSON'
{
  "enabled": true,
  "provider": "dyndns2",
  "interval": 300,
  "source": "interface",
  "interface": "eth0;touch /tmp/bad",
  "zone": "",
  "server": "updates.example.com",
  "login": "user",
  "password": "secret",
  "hostnames": ["home.example.com"]
}
JSON
if "$ROOT/bin/ddnsctl" validate "$TMP/bad.json" >/dev/null 2>&1; then
  echo "unsafe DDNS interface was accepted" >&2
  exit 1
fi

echo "ddns-render-test: PASS"
