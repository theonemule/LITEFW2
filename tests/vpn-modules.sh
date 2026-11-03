#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker run --rm --cap-add NET_ADMIN -v "$PWD:/workspace:ro" alpine:3.24 sh /workspace/tests/vpn-modules-inner.sh
