#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

for mod in openvpn tailscale bind squid snort haproxy ddns; do
  grep -Eq "^[[:space:]]*$mod\)" "$ROOT/bin/modulecfgctl"
done

if grep -q '/etc/litefwm/modules' "$ROOT/bin/modulecfgctl" "$ROOT/bin/modulectl" "$ROOT/bin/ddnsctl"; then
  echo "module JSON sidecar path still exists" >&2
  exit 1
fi
if grep -q 'config.json' "$ROOT/bin/modulecfgctl" "$ROOT/bin/modulectl" "$ROOT/bin/ddnsctl"; then
  echo "module JSON configuration still exists" >&2
  exit 1
fi

grep -Fq '/etc/openvpn/openvpn.conf' "$ROOT/bin/modulecfgctl"
grep -Fq '/etc/bind/named.conf' "$ROOT/bin/modulecfgctl"
grep -Fq '/etc/squid/squid.conf' "$ROOT/bin/modulecfgctl"
grep -Fq '/etc/haproxy/haproxy.cfg' "$ROOT/bin/modulecfgctl"
grep -Fq '/etc/ddclient/ddclient.conf' "$ROOT/bin/modulecfgctl"

echo "module-render-test: PASS"
