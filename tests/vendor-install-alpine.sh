#!/bin/sh
# Exercise actual LiteFW install/remove commands in disposable Alpine 3.24.
set -eu
cd "$(dirname "$0")/.."
command -v docker >/dev/null 2>&1 || { echo 'Docker required for vendor integration checks' >&2; exit 1; }
docker run --rm --network bridge -v "$PWD":/workspace:ro alpine:3.24 sh -ec '
  cd /workspace
  apk add --no-cache jq openrc >/dev/null
  for m in cloudflared captive; do
    echo "CASE vendor/$m full-install"
    ./modules/$m/module.sh install >/tmp/litefw-module.log 2>&1 ||
      { tail -35 /tmp/litefw-module.log >&2; exit 1; }
    PATH=/usr/sbin:/usr/bin:/sbin:/bin ./modules/$m/module.sh installed ||
      { echo "$m was not detected as installed" >&2; exit 1; }
    ./modules/$m/module.sh meta | jq -e --arg id "$m" ".id == \$id" >/dev/null
    echo "PASS $m Alpine install and native service verification"
  done
  for m in cloudflared captive; do
    ./modules/$m/module.sh uninstall >/tmp/litefw-remove.log 2>&1 ||
      { tail -25 /tmp/litefw-remove.log >&2; exit 1; }
    if PATH=/usr/sbin:/usr/bin:/sbin:/bin ./modules/$m/module.sh installed >/dev/null 2>&1; then
      echo "$m still detected as installed after remove" >&2; exit 1
    fi
    echo "PASS $m uninstalled without modifying Alpine repositories"
  done
  if grep -q "/edge/" /etc/apk/repositories; then
    echo "Installer unexpectedly changed Alpine repositories" >&2; exit 1
  fi
'
