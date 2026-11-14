#!/bin/sh
# Remote-Docker-safe in-place runtime upgrade smoke. Never touches the host.
set -eu
cd "$(dirname "$0")/.."
tar -c --exclude='./dist' --exclude='./qa-results' --exclude='./.git' . |
  docker run --rm -i --privileged --network bridge alpine:3.24 sh -ec '
    mkdir -p /src
    tar xf - -C /src
    sh /src/tests/inplace-upgrade-inner.sh
  '
