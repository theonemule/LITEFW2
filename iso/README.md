# LiteFWM appliance ISO

tools/build-appliance-iso.sh builds the x86_64 LiteFWM appliance installer
from Alpine's standard mkimage profile plus the LiteFWM overlay. The default
base is Alpine 3.24.

The ISO is self-contained for a normal sys disk installation. The installer
does not need an Internet connection to install Alpine, the kernel, the
bootloader, the LiteFWM runtime, or the management UI.

## Installed base appliance

The installed system keeps the base intentionally small. Its explicit APK
world contains:

- Alpine base and Alpine setup tools
- ifupdown-ng and iproute2
- iptables
- dnsmasq
- jq and util-linux
- OpenSSH
- lighttpd plus HTTP auth support
- apache2-utils for htpasswd
- sudo and BusyBox OpenRC integration

The ISO repository also carries the LTS kernel, BIOS and UEFI bootloader
packages, ext filesystem tools, FAT tools, and the small generic firmware
bundle required to let Alpine setup-disk complete without reaching a mirror.

The common wired appliance drivers in Alpine 3.24 (Intel e1000/e1000e/igb/igc/
ixgbe/i40e/ice, Realtek r8169, Broadcom, Mellanox, QLogic, Chelsio, VirtIO,
VMware and Hyper-V) do not declare external firmware packages, so the image
does not include the very large catch-all Intel/Mellanox firmware bundles.

## Optional modules available offline

BIND, OpenVPN/Easy-RSA, and inadyn remain optional and are not installed by
default. Their APKs and dependency closure are present in the ISO package
repository so the installer media contains everything LiteFWM currently
supports.

## Installer flow

Run `setup-alpine` once for the entire installation.
The ISO keeps Alpine's installer rather than replacing it.
/usr/local/sbin/setup-alpine wraps the stock setup-alpine flow and inserts
one LiteFWM step immediately before Alpine's Disk & Install phase. The
operator selects the WAN / Internet-edge interface and then the LAN / internal
interface, followed by a mandatory web administrator password and confirmation, all within
the same `setup-alpine` command.
Only a bcrypt hash is persisted. The appliance never creates a random password
or writes a plaintext credential file.

The live ISO accepts `root` at the local console with **no root password**,
and `setup-alpine` suppresses Alpine's separate root-password prompt.
The installed appliance preserves passwordless local-console root access;
remote SSH disallows empty-password authentication and root password login.

lfw-setup applies those roles to the live network and rewrites the native
network configuration so the normal Alpine sys install carries the selected
network configuration forward.

The stock installer remains available separately, and the live image contains
lfw-setup for console recovery.

## Regression tests

tests/iso-wan-lan-smoke.py boots the ISO as a two-NIC firewall and verifies
LAN-to-WAN NAT, WAN-to-LAN port forwarding, and default-deny unsolicited WAN
traffic.

tests/iso-offline-install-smoke.py creates a blank disk and boots the ISO with
no NIC. It resolves the complete package set with APK network access disabled,
performs a real setup-disk sys installation, reboots from the installed disk,
and verifies the Alpine base, LiteFWM CLI/API/UI/configuration, and OpenRC
services. This prevents an accidental Internet mirror from masking a missing
package in the ISO.
