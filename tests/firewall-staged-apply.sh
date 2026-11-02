#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker run --rm --privileged --network bridge -v "$PWD":/src:ro alpine:3.24 sh /src/tests/firewall-staged-inner.sh
