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

The live ISO console opens the LiteFW management menu automatically. Select **1) Install LiteFW to disk**
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

## Temporary root SSH console access

On an installed appliance, choose **7) Enable temporary root SSH access (set password)**.
The console asks for a Linux root password and restarts SSH immediately. While
enabled, sshd listens on a LAN IPv4 address only (preferably 10.0.1.199) and
accepts root password login. The screen clearly shows that temporary access
is ENABLED and reminds the operator to disable it when finished.

Choose **8) Disable temporary root SSH access (no reboot)** to restore SSH
key-only policy and clear the root password immediately, without rebooting.
At boot, LiteFW also revokes any unclosed temporary access as a safety fallback.
This is independent of the Web UI administrator password and never enables DHCP.

The disk installer persists the network configuration and an installed-system marker. An installed appliance never shows the installation option; calling the disk installer directly also fails. Its console starts with WAN/LAN administration.

The Web UI listens exclusively on IPv4 addresses belonging to LAN segments, never on WAN or unassigned NICs. If there is no LAN address, it binds only to loopback. The firewall independently drops non-LAN management TCP traffic before conntrack and arbitrary user rules, so an explicit WAN firewall allow cannot expose the Web UI. Network role changes regenerate the listener configuration.
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
## Upgrading 2.2.7 to 2.2.8 without reinstalling

From an authenticated development machine holding the LiteFW source, run:

```sh
./tools/upgrade-litefw.sh root@10.0.1.199 /var/lib/sandbox-mcp/.ssh/litefw_vm107_migrate
```

The script builds an application-only runtime bundle and sends it via SSH. The
appliance runs `litefw-upgrade`, validates the supported forward-only 2.2.x version
transition, saves an application rollback archive and a configuration backup in
`/root/litefw-upgrade-backups/`, updates only app/runtime files, then tests
the control API and web server configuration. This does **not** run the installer
or touch network interfaces, IP addresses, DHCP scopes, reservations, BIND
configuration/zones, user credentials, or firewall/NAT rules. It does **not**
restart the firewall or require a reboot. Refresh the browser to see the UI.

For a future offline/manual upgrade, copy the release
`litefw2-2.2.8-runtime.tar.gz` to the appliance, and run:

```sh
litefw-upgrade /path/to/litefw2-2.2.8-runtime.tar.gz
```

**DHCP behavior:** The DHCP screen lists every physical, bridge or VLAN
interface. Only configured static-LAN interfaces can run a DHCP service. All
DHCP servers default to OFF; imported reservations are editable with the server
disabled. Pressing Configure never implicitly enables the DHCP server.

**Firewall behavior:** Rules are shown in natural language, including imported
source-inversion anti-spoof rules. Each rule has up/down buttons; moving a rule
across an anti-spoofing rule prompts for confirmation. The underlying rule is
moved without rewriting its match semantics. Imported rules remain read-only
for field editing; technical iptables details are available if needed.

## Upgrades from the System page

The System → Software updates card checks the official GitHub release and
reports whether a newer version exists. After confirmation, Install update
downloads the fixed official release bundle and SHA256SUMS, verifies the
archive checksum, and invokes the runtime upgrader with backups and rollback.
No reboot or DHCP/network/firewall configuration mutation is performed.

For offline installations or private releases, upload a trusted official
`litefw2-VERSION-runtime.tar.gz` in the same card. The upload is restricted
to 4 MB and validated server-side before extraction. In an online update,
HTTPS and GitHub release SHA-256 verification are required.

## 2.2.9 — Advanced per-interface DHCP options

Every physical/VLAN/bridge interface has a separate DHCP options editor.
You can configure the dynamic lease pool, lease duration, client default
gateway (option 3), DNS resolvers (6), domain suffix (15), DNS search list
(119), NTP (42), WINS (44), and optional PXE boot filename/server (66/67).

The **Enable DHCP server** checkbox starts unchecked. Saving with it
unchecked writes the options to `/etc/litefwm/dhcp-scopes/IFACE.json` and
**never starts DHCP or opens UDP 67**. The options survive service disablement,
reboots and subsequent in-place runtime upgrades. Enabling DHCP on an
unconfigured or WAN interface is refused by the API. When enabled, dnsmasq
receives per-interface tagged options; range validation excludes the
firewall's own address.

DHCP DNS server options are addresses **given to DHCP clients**; they do not
change the firewall's own DNS resolver configuration or its BIND zones.
Those remain configurable separately under DNS.

2.2.8 was already published, so this feature is released as 2.2.9.

## 2.2.10 — Staged firewall changes and console break-glass

The Firewall screen reads the live firewall policy on entry. All edits,
reordering, new rules and port forwards remain **local browser drafts** until
Apply changes is pressed. Discard edits restores the previously read policy.
The browser sends its original live-rule baseline with the draft; concurrent
changes made from SSH or another browser cause a conflict instead of silently
overwriting newer rules. Existing imported/unmanaged iptables rules are kept
exactly as-is when reordered; they are not rewritten through the simplified
editor. Edits of managed rules use the normal native rule validation.

The backend builds one complete iptables-restore transaction covering
LFW_FWD, LFW_IN and LFW_DNAT, atomically applies the change, and requires
an explicit in-browser Keep confirmation within 120 seconds. Until that
confirmation, the old policy remains the boot policy and a watchdog
restores the old live policy if the browser disconnects or confirmation
is omitted. Confirmed policies are saved for reboot. DHCP and BIND
configuration are never touched by applying firewall rules.

The Proxmox/physical LiteFW console has two new options:

- Emergency: bypass firewall filtering (temporary), with explicit YES warning
- Restore firewall rules (no reboot)

The temporary bypass adds top-priority ACCEPT to INPUT and FORWARD, preserving
NAT and all original rules in a volatile snapshot; it is **very permissive**
and potentially exposes services beyond the LAN. Only an administrator at
the local console can activate it; it is not exposed over HTTP. Restoration
removes the bypass immediately. Boot always restores the last confirmed
firewall rules from disk. The console also shows whether bypass is active.

## LiteFW 2.2.11 — BIND9 server settings and zone-file editor

BIND DNS Settings can now configure multiple recursive upstream forwarders,
forward-first vs forward-only, DNSSEC validation, minimal answers, max cached
positive/negative TTL, IPv4 listener/ACL/zone transfer rules, restricted
recursion, and optional IPv6 listeners. Recursive clients cannot be public.
The settings are validated using named-checkconf before replacement.

The DNS and Modules BIND sections list authoritative zones, including imported
zone files carrying a LiteFW zone marker. Click **Edit zone file** to review and
modify complete native BIND zone text. **Create / import zone file** accepts a
zone name and pasted or uploaded .zone/.db/.txt file contents (64 KiB maximum).
The server rejects malformed zone files using named-checkzone, preserves the
previous zone on failure, checks a SHA-256 baseline against concurrent edits,
and saves copies of prior zone files under /root/litefw-dns-backups/.

Zone files must contain valid SOA/NS records. Increase the SOA serial whenever
editing a live zone. BIND $INCLUDE and $GENERATE are blocked by the editor to
prevent arbitrary file access and excessive resource consumption.

As with all LiteFW runtime upgrades, the upgrade to 2.2.11 changes only code:
existing DNS forwarders, zones, firewall/NAT, DHCP reservations, and enabled
states are not changed until you explicitly save a BIND setting or zone.

## LiteFW 2.2.12 — Plain DNS upstream provider presets

The dnsmasq DNS and BIND9 settings editors offer an Upstream DNS provider /
protection level selector, with profile descriptions, primary/secondary IPv4
addresses, and links to official provider documentation. Selections include
Cloudflare Standard/Malware/Family, OpenDNS Home/FamilyShield/Sandbox,
Quad9 secure/unfiltered, CleanBrowsing Security/Adult/Family, AdGuard
default/family/non-filtering, Google Public DNS, and Custom DNS servers.

- A preset fills its matched IPv4 servers into native dnsmasq server= and
  BIND forwarders; neither stores a separate provider database.
- Existing resolver IPs are detected from live config. No match means Custom,
  preserving existing addresses.
- dnsmasq retains Automatic WAN/system DNS with no fixed resolvers.
- BIND retains Direct recursion with no forwarders.
- Filtered BIND presets force forward only; to avoid unfiltered root fallback.
  Unfiltered and custom forwarders retain their existing first/only setting.
- When BIND owns DNS port 53, dnsmasq choices are saved but cannot serve
  client DNS requests until BIND releases port 53.
- These use ordinary plaintext UDP/TCP DNS, NOT DoH or DoT. Domain filtering
  is best effort and can be bypassed with alternate DNS, VPN, encrypted DNS.
  OpenDNS Home custom filtering needs an OpenDNS account and registered network.
- Merely upgrading does not change DNS, BIND zones, firewall, DHCP, routing.

Provider documentation:
https://developers.cloudflare.com/1.1.1.1/ip-addresses/
https://www.opendns.com/setupguide/
https://www.cisco.com/c/en/us/support/docs/security/umbrella/225803-understand-opendns-familyshield.html
https://docs.quad9.net/services/
https://cleanbrowsing.org/filters
https://adguard-dns.io/en/public-dns.html
https://developers.google.com/speed/public-dns/docs/using
