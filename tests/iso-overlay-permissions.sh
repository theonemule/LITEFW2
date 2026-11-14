#!/bin/sh
# Verify the packaged Alpine apkovl does not turn / into mode 0700, which
# would lock out lighttpd and other service users on a live-ISO boot.
set -eu
cd "$(dirname "$0")/.."
tar --exclude='./dist' --exclude='./qa-results' --exclude='./.git' -cf - . | \
  docker run --rm -i alpine:3.24 sh -ec '
    mkdir -p /src /tmp/overlay-test
    tar xf - -C /src
    cd /tmp/overlay-test
    LITEFWM_SOURCE=/src sh /src/iso/genapkovl-litefwm.sh litefw
    root_mode=$(tar -tzvf litefw.apkovl.tar.gz | head -n1 | cut -c1-10)
    [ "$root_mode" = drwxr-xr-x ] || { echo "Unsafe overlay root mode: $root_mode"; exit 1; }
    tar -tzvf litefw.apkovl.tar.gz | grep "etc/sudoers.d/litefwm" | grep -q "^-r--r-----"
    echo "PASS: apkovl keeps the guest root searchable and sensitive files protected"
  '
