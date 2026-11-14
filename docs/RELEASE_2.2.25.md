# LiteFW2 2.2.25 — native nftables firewall release

This release replaces LiteFW2's iptables packet-filter and NAT implementation
with native **nftables** (`inet litefw` table) and continues using **iproute2**
for interface and routing management.

- Unified, ordered source-to-destination policy across host INPUT/OUTPUT and
  forwarded traffic; IP/CIDR/range/list and port/range/list selectors.
- Native masquerading, port forwards, GeoIP sets, module rules and preserved
  unrelated nftables tables.
- Apply/confirm rollback, LAN-only management and console breakglass retained.
- Updated Alpine x86_64 boot/install ISO, OpenRC nftables service and offline
  package repository, plus native module/runtime tooling.
- End-to-end QEMU tests include disk installation and reboot, live ISO WAN/LAN
  traffic, and the same routing and HTTP API tests from the installed disk.
- Standalone CLI and API documentation regenerated for 2.2.25.

## Download artifacts

The GitHub release contains `litefw2-2.2.25-alpine3.24-x86_64.iso`,
`litefw2-2.2.25-runtime.tar.gz`, `litefw-2.2.25-cli.sh` and `SHA256SUMS`.
Always verify the checksum manifest after downloading.

## Upgrade safety

**Fresh installs:** Boot the v2.2.25 ISO and install onto a dedicated Alpine
appliance as described in `iso/README.md`.

**Existing iptables-based LiteFW2 installs (including v2.2.24 and earlier):**
The runtime archive is **not a safe migration mechanism**. Do not apply the
in-place runtime update on these installations; it deliberately refuses
an iptables-to-nftables cutover. Back up your existing routing, interfaces,
DNS/DHCP, user credentials, module configuration, filter/NAT and persistent
rules; then plan a separate console-backed conversion with rollback, or
prepare a fresh install and manually reproduce/verify the configuration.

**Already migrated nftables installations:** The `litefw-upgrade` runtime
updater still supports a newer same-series version and preserves appliance
configuration. Its backup now includes native `/etc/nftables.nft` and
`/etc/litefw-addons` alongside any legacy iptables rule files.

This release does not automatically install or update a running firewall.
