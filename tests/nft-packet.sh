#!/bin/sh
# Requires Docker with privileged network namespace support.
set -eu
cd "$(dirname "$0")/.."
docker run --rm --privileged --network bridge -v "$PWD":/src:ro alpine:3.24 sh /src/tests/nft-packet-inner.sh