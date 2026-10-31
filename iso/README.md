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

The boot console opens the LiteFW management menu automatically. Select **1) Install LiteFW to disk**
to run the single appliance installer. This retains Alpine keyboard, timezone,
APK repository, and disk setup, while replacing Alpine's unbounded network and
Unix account prompts with LiteFW's setup.

The network wizard selects one WAN and one LAN, even with additional NICs present.
WAN supports bounded DHCP (8 seconds), static IPv4, and offline fallback.
LAN supports an optional 802.1Q VLAN ID (1–4094) and static IPv4 address.
Other physical NICs remain unassigned.

The operator chooses the **web UI administrator username and password**
(12+ characters, stored only as a bcrypt hash). OpenSSH is installed and enabled
automatically. SSH forbids empty passwords; it does not share the web UI
credentials. The physical/VM console opens the LiteFW management menu without
a separate root-password challenge, and exposes network, administrator, and
recovery settings. Only trusted operators should have console access.

The disk installer persists the existing LiteFW network configuration. On an
installed appliance the console remains available for reconfiguration.
Versioning follows the repository `VERSION` file; the ISO is named
`litefw2-<version>-alpine3.24-x86_64.iso`.

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