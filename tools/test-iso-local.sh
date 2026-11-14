#!/bin/sh
# Disposable full-ISO boot/installation QA using Docker + software-emulated QEMU.
# Does not require /dev/kvm or host-accessible bind mounts (remote Docker safe).
# Usage: tools/test-iso-local.sh dist/litefw2-...iso [offline|wanlan|both]
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
ISO=$1
MODE=$2
[ -n "$ISO" ] || { echo "ISO file is required" >&2; exit 2; }
[ -n "$MODE" ] || MODE=both
case "$MODE" in offline|wanlan|both|installed) :;; *) echo 'Choose offline, wanlan, installed or both' >&2; exit 2;; esac
case "$ISO" in /*) :;; *) ISO="$ROOT/$ISO";; esac
[ -s "$ISO" ] || { echo "ISO missing or empty: $ISO" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo 'Docker is required' >&2; exit 1; }
C="litefw-qemu-qa-$(date +%s)-$$"
OUT="$ROOT/qa-results/qemu"
mkdir -p "$OUT"
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM HUP
docker create --name "$C" --privileged --shm-size=1024m \
  -e "MODE=$MODE" --network bridge alpine:3.24 /bin/sh -ec '
  apk add --no-cache -q qemu-system-x86_64 qemu-img py3-pexpect iproute2 sudo \
      busybox-extras python3 curl jq nftables iputils >/tmp/qa-packages.log 2>&1 || {
        tail -60 /tmp/qa-packages.log
        exit 1
      }
  mkdir -p /dev/net /tmp/qa-results
  [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
  [ -e /src/iso-under-test.iso ] || { echo "ISO not copied"; exit 1; }
  export LITEFWM_OFFLINE_WORK=/tmp/qa-results/offline
  # The local development box has working hardware virtualization. Use it
  # when exposed to this disposable container; TCG remains the fallback.
  if [ -c /dev/kvm ]; then export LITEFWM_QEMU_ACCEL=kvm
  else export LITEFWM_QEMU_ACCEL=tcg; fi
  echo "QEMU acceleration: $LITEFWM_QEMU_ACCEL"
  if [ "$MODE" = offline ] || [ "$MODE" = both ]; then
    echo "== QEMU OFFLINE INSTALL AND DISK REBOOT =="
    python3 -u /src/tests/iso-offline-install-smoke.py /src/iso-under-test.iso \
      > /tmp/qa-results/offline.log 2>&1 || {
        tail -90 /tmp/qa-results/offline.log
        exit 10
      }
    tail -18 /tmp/qa-results/offline.log
  fi
  if [ "$MODE" = wanlan ] || [ "$MODE" = both ]; then
    echo "== QEMU WAN/LAN AND FIREWALL RULES =="
    python3 -u /src/tests/iso-wan-lan-smoke.py /src/iso-under-test.iso \
      > /tmp/qa-results/wanlan.log 2>&1 || {
        tail -90 /tmp/qa-results/wanlan.log
        exit 11
      }
    tail -24 /tmp/qa-results/wanlan.log
  fi
  if [ "$MODE" = both ]; then
    # Test routed interfaces and authenticated HTTP after the installer has
    # written and rebooted a real disk. Keep offline disk pristine.
    echo "== QEMU INSTALLED DISK WAN/LAN AND RULES =="
    cp /tmp/qa-results/offline/disk.qcow2 /tmp/qa-results/installed-network.qcow2
    export LITEFWM_WANLAN_DISK=/tmp/qa-results/installed-network.qcow2
    python3 -u /src/tests/iso-wan-lan-smoke.py /src/iso-under-test.iso \
      > /tmp/qa-results/installed-wanlan.log 2>&1 || {
        tail -90 /tmp/qa-results/installed-wanlan.log
        exit 12
      }
    tail -24 /tmp/qa-results/installed-wanlan.log
    unset LITEFWM_WANLAN_DISK
  fi
  if [ "$MODE" = installed ]; then
    echo "== QEMU EXISTING INSTALLED DISK WAN/LAN AND RULES =="
    export LITEFWM_WANLAN_DISK=/tmp/installed-disk.qcow2
    python3 -u /src/tests/iso-wan-lan-smoke.py /src/iso-under-test.iso \
      > /tmp/qa-results/installed-wanlan.log 2>&1 || {
        tail -90 /tmp/qa-results/installed-wanlan.log
        exit 12
      }
    tail -24 /tmp/qa-results/installed-wanlan.log
  fi
  echo "PASS: selected local ISO/QEMU suites ($MODE)"
' >/dev/null
# docker cp works across mount namespaces and remote Docker daemons.
# A streamed tar includes only source: excluded QA logs and ISO artifacts
# avoid multi-GB copies to a remote Docker daemon.
tar --transform='s#^\.#src#' --exclude='./dist' --exclude='./qa-results' \
  --exclude='./.git' -C "$ROOT" -cf - . | docker cp - "$C:/"
docker cp "$ISO" "$C:/src/iso-under-test.iso"
if [ "$MODE" = installed ]; then
  [ -s "$OUT/offline/disk.qcow2" ] || { echo "No previously installed test disk available" >&2; exit 3; }
  docker cp "$OUT/offline/disk.qcow2" "$C:/tmp/installed-disk.qcow2"
fi
set +e
docker start -a "$C"
rc=$?
set -e
# Preserve guest serial traces and test output on failure as well as success.
docker cp "$C:/tmp/qa-results/." "$OUT/" >/dev/null 2>&1 || true
# Preserve serial output from the WAN/LAN boot even if the guest fails.
docker cp "$C:/dev/shm/litefwm-iso-smoke/serial.log" "$OUT/wanlan-serial.log" >/dev/null 2>&1 || true
echo "QEMU test result code: $rc"
echo "QA logs: $OUT"
exit "$rc"
