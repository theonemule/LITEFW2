#!/bin/sh
# Run native Suricata rules and WireGuard peer workflows in ephemeral Alpine.
set -eu
cd "$(dirname "$0")/.."
command -v docker >/dev/null 2>&1 || { echo "Docker required" >&2; exit 1; }
for test in suricata-rules-integration.sh wireguard-peer-integration.sh; do
  echo "=== $test ==="
  docker run --rm --privileged --network bridge -v "$PWD":/workspace:ro \
    alpine:3.24 sh "/workspace/tests/$test"
done
