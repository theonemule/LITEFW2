#!/bin/sh
# From a checked-out LiteFW source tree:
#    ./tools/upgrade-litefw.sh root@10.0.1.199 [identity-key]
# Requires key-based SSH. No VM reboot or ISO reinstall.
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
dest=${1:?Usage: ./tools/upgrade-litefw.sh root@HOST [identity-key]}
identity=${2:-${LITEFW_SSH_KEY:-$HOME/.ssh/litefw_vm107_migrate}}
[ -r "$identity" ] || { echo "SSH identity key not found: $identity" >&2; exit 1; }
[ "$(cat "$src/VERSION")" = 2.2.11 ] || { echo "Expected LiteFW 2.2.11 checkout"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
tar -czf "$tmp/litefw-runtime.tar.gz" -C "$src" VERSION bin lib modules cgi www
cp "$src/bin/litefw-upgrade" "$tmp/litefw-upgrade"
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$identity" "$dest" 'install -d -m 0700 /root/litefw-upgrade-staging'
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$identity" \
  "$tmp/litefw-runtime.tar.gz" "$tmp/litefw-upgrade" "$dest:/root/litefw-upgrade-staging/"
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$identity" "$dest" \
  'sh /root/litefw-upgrade-staging/litefw-upgrade /root/litefw-upgrade-staging/litefw-runtime.tar.gz'
