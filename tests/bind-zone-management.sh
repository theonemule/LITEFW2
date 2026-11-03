#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker run --rm --network bridge -v "$PWD":/src:ro alpine:3.24 sh /src/tests/bind-zone-management-inner.sh
