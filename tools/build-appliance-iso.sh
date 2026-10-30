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

docker run --rm \
  --tmpfs /tmp:rw,exec,size=7g \
  -e ALPINE_VERSION="$ALPINE_VERSION" \
  -e ALPINE_BRANCH="$ALPINE_BRANCH" \
  -e ARCH="$ARCH" \
  -v "$ROOT:/src:ro" \
  -v "$OUT:/out" \
  "alpine:$ALPINE_VERSION" /bin/sh -euxc '
    apk add --no-cache abuild apk-tools alpine-conf busybox fakeroot git syslinux xorriso squashfs-tools grub mtools dosfstools
    git clone --depth 1 --filter=blob:none --sparse --branch "$ALPINE_BRANCH" https://gitlab.alpinelinux.org/alpine/aports.git /tmp/aports
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

echo
echo "LiteFWM ISO output:"
find "$OUT" -maxdepth 1 -type f -name '*litefwm*.iso' -print
