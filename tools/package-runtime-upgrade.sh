#!/bin/sh
# Produce the exact GitHub release asset expected by the LiteFW UI updater.
# Usage: ./tools/package-runtime-upgrade.sh [output-directory]
# No network or appliance configuration changes are made.
set -eu
umask 022
src=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
out=${1:-"$src/dist"}
version=$(cat "$src/VERSION")
printf '%s' "$version" | grep -Eq '^2\.2\.[0-9]+$' || {
  echo "Expected a version of the form 2.2.N, got $version" >&2
  exit 1
}
for f in VERSION bin/litefw-upgrade bin/lfwctl cgi/api.cgi www/app.js modules/manifest.json; do
  [ -s "$src/$f" ] || { echo "Missing required runtime file: $f" >&2; exit 1; }
done
mkdir -p "$out"
out=$(CDPATH='' cd -- "$out" && pwd -P)
bundle="litefw2-$version-runtime.tar.gz"
stage=$(mktemp "$out/.runtime.XXXXXX")
trap 'rm -f "$stage"' EXIT HUP INT TERM
tar -czf "$stage" -C "$src" VERSION bin lib modules cgi www
[ "$(wc -c <"$stage")" -le 4194304 ] || {
  echo "Upgrade package exceeds the 4 MiB appliance upload limit" >&2
  exit 1
}
tar -tzf "$stage" | grep -Fxq 'modules/manifest.json'
mv "$stage" "$out/$bundle"
trap - EXIT HUP INT TERM
cli="litefw-$version-cli.sh"
install -m 0755 "$src/bin/litefw" "$out/$cli"
(cd "$out" && sha256sum "$bundle" "$cli" > SHA256SUMS)
printf 'Version: %s\nArchive: %s\nSHA256: %s\n' \
  "$version" "$out/$bundle" "$(sha256sum "$out/$bundle" | awk '{print $1}')"
