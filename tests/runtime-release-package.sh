#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
./tools/package-runtime-upgrade.sh "$stage"
ver=$(cat VERSION)
bundle="$stage/litefw2-$ver-runtime.tar.gz"
[ -s "$bundle" ] && [ "$(wc -c <"$bundle")" -le 4194304 ]
(cd "$stage" && sha256sum -c SHA256SUMS)
tar -tzf "$bundle" | grep -Fxq 'modules/manifest.json'
tar -tzf "$bundle" | grep -Fxq 'modules/dnsmasq/module.sh'
tar -tzf "$bundle" | grep -Fxq 'modules/ddns/cloudflare-legacy.sh'
tar -tzf "$bundle" | grep -Fxq 'modules/ddns/cloudflare-cron'
tar -tzf "$bundle" | grep -Fxq 'modules/ddns/cloudflare-configure.sh'
tar -tzf "$bundle" | grep -Fxq 'modules/ddns/cloudflare-schedule.sh'
tar -tzf "$bundle" | grep -Fxq 'www/app.js'
grep -Fq "/app.js?v=$ver" www/index.html
[ "$(tar -xzOf "$bundle" VERSION)" = "$ver" ]
grep -Fq 'Publish LiteFW runtime upgrade' .github/workflows/runtime-upgrade.yml
grep -Fq 'gh release upload "$tag" dist/SHA256SUMS --clobber' .github/workflows/appliance-iso.yml
grep -Fq '_file="litefw2-$_latest-runtime.tar.gz"' lib/sys.sh
echo "PASS: UI updater filename matches GH asset; versioned archive and checksums validate"
