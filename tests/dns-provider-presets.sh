#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node tests/dns-provider-presets.js
docker run --rm --network bridge -v "$PWD":/src:ro alpine:3.24 sh /src/tests/dns-provider-dnsmasq-inner.sh
