#!/bin/sh
# Run native WireGuard peer and Tailscale connectivity workflows in ephemeral Alpine.
set -eu
cd "$(dirname "$0")/.."
command -v docker >/dev/null 2>&1 || { echo "Docker required" >&2; exit 1; }
for test in wireguard-peer-integration.sh tailscale-integration.sh; do
  echo "=== $test ==="
  docker run --rm --privileged --network bridge -v "$PWD":/workspace:ro \
    alpine:3.24 sh "/workspace/tests/$test"
done
