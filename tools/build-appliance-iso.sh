#!/bin/sh
# Build the LiteFWM x86_64 installer ISO using Alpine's mkimage tooling.
# By default this uses Docker so the build is reproducible from a non-Alpine host.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
OUT=${OUTDIR:-"$ROOT/dist"}
ALPINE_VERSION=${ALPINE_VERSION:-3.24}
ALPINE_BRANCH=${ALPINE_BRANCH:-${ALPINE_VERSION}-stable}
ARCH=${ARCH:-x86_64}
mkdir -p "$OUT"

command -v docker >/dev/null 2>&1 || {
  echo "docker is required for this build script" >&2
  echo "Alternatively copy the two iso build scripts into Alpine aports/scripts and run mkimage directly." >&2
  exit 1
}

# Docker may be remote or hosted outside the source mount namespace, so
# transferring the source using docker cp is safer than a host bind mount.
# Work entirely inside a temporary, disposable build container. No live
# appliance configuration is mounted or modified.
BUILD_CONTAINER="litefw-iso-build-$(date +%s)-$$"
cleanup() { docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT HUP INT TERM
# Use disk-backed container scratch instead of RAM tmpfs that starves CI.
docker create --name "$BUILD_CONTAINER" \
  -e ALPINE_VERSION="$ALPINE_VERSION" \
  -e ALPINE_BRANCH="$ALPINE_BRANCH" \
  -e ARCH="$ARCH" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "alpine:$ALPINE_VERSION" /bin/sh -euxc '
    mkdir -p /out
    apk add --no-cache abuild apk-tools alpine-conf busybox fakeroot git syslinux xorriso squashfs-tools grub mtools dosfstools
    # Limit squashfs compression concurrency and RAM. The default worker
    # count can exhaust a 16 GiB CI/dev box while building the kernel modloop.
    mv /usr/bin/mksquashfs /usr/bin/mksquashfs.real
    printf "%s\n" "#!/bin/sh" \
      "exec /usr/bin/mksquashfs.real \"\$@\" -processors 2 -mem 512M" \
      > /usr/bin/mksquashfs
    chmod 0755 /usr/bin/mksquashfs
    git clone --depth 1 --filter=blob:none --sparse --branch "$ALPINE_BRANCH" https://github.com/alpinelinux/aports.git /tmp/aports
    git -C /tmp/aports sparse-checkout set scripts
    cp /src/iso/mkimg.litefwm.sh /src/iso/genapkovl-litefwm.sh /tmp/aports/scripts/
    chmod +x /tmp/aports/scripts/genapkovl-litefwm.sh
    cp -a /src /tmp/litefwm-src
    adduser -D builder
    addgroup builder abuild
    chown -R builder:builder /tmp/aports /tmp/litefwm-src /out
    su builder -c "abuild-keygen -a -n"
    key=$(find /home/builder/.abuild -name "*.rsa" | head -n1)
    pub="$key.pub"
    cp "$pub" /etc/apk/keys/
    chown builder:builder "$pub"
    su builder -c "cd /tmp/aports && LITEFWM_SOURCE=/tmp/litefwm-src PACKAGER_PRIVKEY=$key ./scripts/mkimage.sh \
      --tag v$ALPINE_VERSION --outdir /out --arch $ARCH --profile litefwm \
      --repository https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main \
      --repository https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community"
  '
# Stream only the tracked/configured source into /src. ISO binaries, test
# output and Git metadata must never be bundled back into a new build.
tar --transform='s#^\.#src#' --exclude='./dist' --exclude='./qa-results' \
  --exclude='./.git' -C "$ROOT" -cf - . | docker cp - "$BUILD_CONTAINER:/"
docker start -a "$BUILD_CONTAINER"
docker cp "$BUILD_CONTAINER:/out/." "$OUT/"
echo
echo "LiteFWM ISO output:"
find "$OUT" -maxdepth 1 -type f -name '*litefwm*.iso' -print