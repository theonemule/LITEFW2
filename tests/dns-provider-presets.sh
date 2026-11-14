#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node tests/dns-provider-presets.js
# The source tree may live outside the Docker daemon's mount namespace.
# Stream a minimal checkout instead of requiring host bind mounts.
tar -c --exclude='./dist' --exclude='./qa-results' --exclude='./.git' . | \
  docker run --rm --network bridge -i alpine:3.24 sh -ec '
    mkdir -p /src; tar xf - -C /src
    sh /src/tests/dns-provider-dnsmasq-inner.sh
  '
