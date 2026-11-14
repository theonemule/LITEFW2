#!/bin/bash
# Disposable Alpine kernel/HTTP/module compatibility suite using Docker's
# streamed source transport: works even when Docker's daemon is remote.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p qa-results/local
pass=0; fail=0
for f in \
  nft-backend-inner.sh nft-unified-inner.sh nft-module-inner.sh \
  firewall-recovery-inner.sh nft-packet-inner.sh \
  api-keys-inner.sh bind-zone-management-inner.sh \
  dns-provider-dnsmasq-inner.sh vpn-modules-inner.sh \
  wireguard-peer-integration.sh simulations-inner.sh; do
  echo "=== RUN $f ==="
  name="lfw-regress-$RANDOM-$$"
  tar -c --exclude='./dist' --exclude='./qa-results' --exclude='./.git' . | \
    timeout 360 docker run --name "$name" --rm -i --privileged --network bridge alpine:3.24 \
      sh -ec 'mkdir -p /workspace; tar xf - -C /workspace; ln -s /workspace /src; apk add -q --no-cache jq iproute2 nftables openssh >/dev/null; cd /workspace; sh "/workspace/tests/$1"' sh "$f" \
      >"qa-results/local/$f.log" 2>&1
  rc=$?
  echo "STATUS $rc $f"
  tail -5 "qa-results/local/$f.log"
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
