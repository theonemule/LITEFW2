#!/bin/sh
# End-to-end Alpine Lighttpd + CGI + privileged controller + standalone CLI.
set -eu
cd "$(dirname "$0")/.."
docker run --rm --network bridge -v "$PWD:/workspace:ro" alpine:3.24 sh /workspace/tests/api-keys-inner.sh
