#!/bin/sh
# LiteFW behavioral integration: disposable privileged network container.
set -eu
cd "$(dirname "$0")/.."
command -v docker >/dev/null 2>&1 || { echo 'Docker is required for behavioral simulation CI' >&2; exit 1; }
# Network bridge is used only to install Alpine test dependencies. Test routes,
# links, packet filtering and FRR are inside the ephemeral container namespace.
docker run --rm --privileged --network bridge \
  --name "litefw-behavior-$$" \
  -v "$PWD:/workspace:ro" \
  alpine:3.24 sh /workspace/tests/simulations-inner.sh
