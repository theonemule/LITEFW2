#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

cat > "$TMP/good.json" <<'JSON'
{
  "hostname":"litefwm",
  "management":{"port":5187,"sshPort":22,"allowSsh":true},
  "interfaces":[
    {"id":"eth0","device":"eth0","type":"physical","managed":true,"mtu":1500,"members":[]}
  ],
  "segments":[
    {"id":"eth0","interface":"eth0","addressMode":"dhcp","address":"","currentAddress":"10.0.1.187/24","gateway":"10.0.1.1","dns":["10.0.1.1"],"dhcp":{"enabled":false}}
  ],
  "firewall":{"defaults":{"input":"accept","forward":"accept","output":"accept"},"rules":[],"nat":{"masquerade":[],"snat":[],"dnat":[]}}
}
JSON

"$ROOT/bin/configctl" validate "$TMP/good.json" >/dev/null

jq '.interfaces[0].device="eth0;touch /tmp/pwned"' "$TMP/good.json" > "$TMP/bad.json"
if "$ROOT/bin/configctl" validate "$TMP/bad.json" >/dev/null 2>&1; then
  echo "unsafe interface device was accepted" >&2
  exit 1
fi

jq '.segments[0].addressMode="static" | .segments[0].address="999.1.1.1/24"' "$TMP/good.json" > "$TMP/bad.json"
if "$ROOT/bin/configctl" validate "$TMP/bad.json" >/dev/null 2>&1; then
  echo "invalid IPv4 CIDR was accepted" >&2
  exit 1
fi

jq '.firewall.rules=[{"source":"any","destination":"any","sourcePort":"any","destinationPort":"443
-A INPUT -j ACCEPT"}]' "$TMP/good.json" > "$TMP/bad.json"
if "$ROOT/bin/configctl" validate "$TMP/bad.json" >/dev/null 2>&1; then
  echo "unsafe firewall port was accepted" >&2
  exit 1
fi

echo "security-validation-test: PASS"
