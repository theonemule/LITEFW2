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
mkdir -p "$LITEFWM_ETC/modules" "$LITEFWM_GENERATED"

write_mod() {
  mod=$1
  mkdir -p "$LITEFWM_ETC/modules/$mod"
  cat > "$LITEFWM_ETC/modules/$mod/config.json"
  chmod 0600 "$LITEFWM_ETC/modules/$mod/config.json"
}

write_mod openvpn <<'JSON'
{
  "enabled":true,"mode":"server","protocol":"udp","port":1194,
  "bindAddress":"0.0.0.0","device":"tun0","network":"10.8.0.0/20",
  "dns":["192.168.10.1"],"pushRoutes":["192.168.10.0/24","192.168.20.0/24"],
  "clientToClient":false,
  "caFile":"/etc/openvpn/ca.crt","certFile":"/etc/openvpn/server.crt","keyFile":"/etc/openvpn/server.key"
}
JSON
"$ROOT/bin/modulecfgctl" validate openvpn >/dev/null
f=$("$ROOT/bin/modulecfgctl" render openvpn)
grep -Fq 'server 10.8.0.0 255.255.240.0' "$f"
grep -Fq 'push "dhcp-option DNS 192.168.10.1"' "$f"
grep -Fq 'push "route 192.168.20.0/24"' "$f"

write_mod bind <<'JSON'
{
  "enabled":true,"zone":"home.arpa",
  "listenSegments":["lan"],"forwarders":["1.1.1.1","9.9.9.9"],
  "allowRecursionSegments":["lan","iot"],
  "records":[{"name":"nas","address":"192.168.10.20"}]
}
JSON
"$ROOT/bin/modulecfgctl" validate bind >/dev/null
paths=$("$ROOT/bin/modulecfgctl" render bind)
named=$(printf '%s
' "$paths" | sed -n '1p')
zone=$(printf '%s
' "$paths" | sed -n '2p')
grep -Fq 'listen-on { 192.168.10.1; };' "$named"
grep -Fq 'allow-recursion { 192.168.10.1/24;192.168.20.1/24; };' "$named"
grep -Fq 'ns1 IN A 192.168.10.1' "$zone"
grep -Fq 'nas IN A 192.168.10.20' "$zone"

write_mod squid <<'JSON'
{
  "enabled":true,"listenSegment":"lan","port":3128,
  "allowedSegments":["lan"],"cacheMb":256,
  "blockedDomains":[".example.invalid"],"visibleHostname":"litefwm"
}
JSON
"$ROOT/bin/modulecfgctl" validate squid >/dev/null
f=$("$ROOT/bin/modulecfgctl" render squid)
grep -Fq 'http_port 192.168.10.1:3128' "$f"
grep -Fq 'acl litefwm_blocked dstdomain .example.invalid' "$f"
grep -Fq 'acl litefwm_allowed src 192.168.10.1/24' "$f"
deny_line=$(grep -n '^http_access deny litefwm_blocked$' "$f" | cut -d: -f1)
allow_line=$(grep -n '^http_access allow litefwm_allowed$' "$f" | cut -d: -f1)
[ "$deny_line" -lt "$allow_line" ]

write_mod snort <<'JSON'
{
  "enabled":true,"interface":"br0","homeNet":"192.168.10.0/24",
  "mode":"ids","configFile":"/etc/snort/snort.conf","extraArgs":"-A alert_fast"
}
JSON
"$ROOT/bin/modulecfgctl" validate snort >/dev/null
f=$("$ROOT/bin/modulecfgctl" render snort)
grep -Fq 'SNORT_INTERFACE="br0"' "$f"
grep -Fq 'SNORT_HOME_NET="192.168.10.0/24"' "$f"

write_mod haproxy <<'JSON'
{
  "enabled":true,"mode":"http","listenAddress":"0.0.0.0","listenPort":8088,
  "balance":"roundrobin",
  "backendServers":[
    {"name":"web1","address":"192.168.10.20:8080","check":true},
    {"name":"web2","address":"192.168.10.21:8080","check":false}
  ]
}
JSON
"$ROOT/bin/modulecfgctl" validate haproxy >/dev/null
f=$("$ROOT/bin/modulecfgctl" render haproxy)
grep -Fq 'server web1 192.168.10.20:8080 check' "$f"
grep -Fq 'server web2 192.168.10.21:8080' "$f"
if grep -Fq 'server web2 192.168.10.21:8080 check' "$f"; then
  echo "HAProxy check=false was ignored" >&2
  exit 1
fi

write_mod tailscale <<'JSON'
{
  "enabled":true,"authKey":"tskey-example","hostname":"litefwm",
  "advertiseRoutes":["192.168.10.0/24","192.168.20.0/24"],
  "acceptRoutes":true,"advertiseExitNode":false,"ssh":false
}
JSON
"$ROOT/bin/modulecfgctl" validate tailscale >/dev/null
shown=$("$ROOT/bin/modulecfgctl" show tailscale)
printf '%s' "$shown" | jq -e '.authKey=="" and .authKeySet==true' >/dev/null
if printf '%s' "$shown" | grep -Fq 'tskey-example'; then
  echo "Tailscale auth key leaked from show" >&2
  exit 1
fi

cat > "$TMP/bad-haproxy.json" <<'JSON'
{
  "enabled":true,"mode":"http","listenAddress":"0.0.0.0","listenPort":80,
  "balance":"roundrobin",
  "backendServers":[{"name":"web1
server injected","address":"192.168.10.20:80","check":true}]
}
JSON
if "$ROOT/bin/modulecfgctl" validate haproxy "$TMP/bad-haproxy.json" >/dev/null 2>&1; then
  echo "unsafe HAProxy server name was accepted" >&2
  exit 1
fi

echo "module-render-test: PASS"
