# LiteFW2 appliance

LiteFW2 is distributed **only as a bootable Alpine Linux x86_64 appliance ISO**. Debian, Ubuntu, Docker-as-product and script-on-existing-host installations are unsupported. The installer provisions a dedicated firewall host; it modifies networking, firewall policy, DHCP and DNS.

## Download and install

Download the ISO and SHA256SUMS from the latest GitHub Release. Verify with `sha256sum -c SHA256SUMS`, boot the ISO on a dedicated machine or VM with WAN and LAN interfaces, and run `setup-alpine`. The installer uses LiteFW2's own WAN/LAN configuration instead of Alpine's default network wizard. It checks DHCP for up to 8 seconds, then offers static addressing or offline installation without stalling disk setup. Back up any target disk first; installation can erase it.

## CI and releases

`.github/workflows/appliance-iso.yml` builds on pushes to `main`, pull requests, and manual dispatch. It tests the produced ISO by installing it into a network-disconnected QEMU VM and booting the installed disk. Successful jobs upload the ISO and checksum as GitHub Actions build artifacts. Tags matching `v*` also publish those exact files as GitHub Release assets. Use a tag matching `v$(cat VERSION)`, for example `v2.0.0` for VERSION 2.0.0. Publishing is gated by a successful offline-install smoke test.

The pinned Alpine build base is 3.24. The ISO includes the supported optional module APKs for offline installation. Build locally with `./tools/build-appliance-iso.sh` on a Docker-capable host.

No Debian installation path is supported. Legacy `install.sh` is retained only for source development and is not a supported appliance distribution path.