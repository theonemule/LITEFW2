# LiteFW modules

Modules are defined in the Git-tracked modules/manifest.json. It contains a
version, Alpine package names, a core (non-removable) flag, and relative paths
to bundled module.sh, install.sh and uninstall.sh scripts. The runtime updater
and installer package this manifest with the module scripts; they do not
fetch or execute remote scripts or install from an unaudited plugin store.

Native executable, OpenRC service and configuration files are the source of
truth for a module's status. A successful script exit alone does not mean
that a module installed successfully. The API rechecks native state after
the installer returns, and reports useful errors if verification fails.

To add an optional module: add its entry to the manifest, implement its
three scripts and required meta/installed/snapshot/firewall actions, expose
the configuration API and dedicated UI page, and add contract tests.
Publish through the usual reviewed LiteFW runtime and ISO release workflow.

## DNS engines

DNSMasq is an always-installed, non-removable core module because it is
used for DHCP. Its DNS listener can be disabled while BIND9 handles
authoritative zones and recursive forwarding. The two engines have separate
configuration pages and independently select upstream resolver providers or
custom servers. Switching back to DNSMasq stops BIND, releasing DNS port 53
without deleting BIND zone files or changing DHCP configuration.

The BIND visual record editor loads even imported zone records with the native
named-compilezone parser. Regular DNS records can be added, edited and removed
with a table and forms. Editing an imported record converts the zone to
canonical BIND format (so source comments/formatting may change), first taking
a backup; all edits use checksums, zone validation and rollback on failures.
The advanced raw source editor remains for specialized zone syntax.

## Dynamic DNS troubleshooting

Inadyn needs the inadyn and inadyn-openrc Alpine packages, available in the
community repository or in the optional packages on the LiteFW installation
ISO. The installer now surfaces Alpine APK errors and verifies both the
inadyn executable and the OpenRC service file before showing success.
A successful installation is not equivalent to configured provider credentials
or a successful public DNS update.

Check repositories and package availability using:
    apk policy inadyn inadyn-openrc
Check the service using:
    rc-service inadyn status
Configure a provider and hostname via Modules > Dynamic DNS.


## Migrated pfSense Dynamic DNS profiles

The Cloudflare legacy updater (modules/ddns/cloudflare-legacy.sh) uses HTTPS
with Global API Key headers. Its credential is restricted to root in
/etc/inadyn/litefw-cloudflare-legacy.json (0600). The key never appears in
URLs, client API responses, or GitHub. The cron helper at
/etc/periodic/15min/litefw-cloudflare is enabled to update every 15 minutes.
It never creates records, overwrites CNAMEs or touches other zones. The DDNS
module page displays its status and last verified public IPv4.

OpenDNS networks use native Inadyn, configured via the Dynamic DNS form.
Both clients work behind the upstream pfSense firewall: each discovers the
public IPv4 through HTTPS instead of treating an RFC1918 WAN as public.

For long-term Cloudflare use, migrate the legacy Global API Key to a zone-scoped
API token and use the Inadyn Cloudflare bearer-token provider. pfSense source
DDNS entries may be kept disabled for rollback to avoid competing updates.


### Editing Cloudflare DNS from LiteFW

On Modules > Dynamic DNS, Cloudflare **Configure** allows editing the zone,
list of **existing A records**, account email, credential, enabled state, and
cron interval (5/15/30/60 minutes). Blank credential input preserves the
existing Global API Key. Before saving, the appliance validates the proposed
settings against Cloudflare with **read-only** API calls; CNAMEs, unsupported
record types, and unknown hosts are rejected. Changes are backed up and saved
with root-only permissions. Cron scheduling is idempotent, preserves unrelated
root jobs, removes the old fixed periodic job, and survives runtime upgrades.
The detected public IPv4 and last successful check remain read-only status.

## Optional connectivity, routing, VPN and network modules (2.2.24)

All modules ship in the tracked runtime manifest and remain off until explicitly
installed, configured, and started. An installed status verifies required
native packages, executable, and (when appropriate) OpenRC service.

| Module | Implementation |
| --- | --- |
| GeoIP Blocking | HTTPS IPdeny aggregated IPv4 country feeds, atomic ipset updates, generated LiteFW INPUT/FORWARD block rules. |
| Tailscale | Alpine/OpenRC tailnet peer connectivity, explicit Connect, protected one-time auth-key use, optional subnet advertisement and remote-route acceptance. |
| WireGuard | wg-quick with protected private key, peer configuration, UDP firewall rule, OpenRC start/stop and boot persistence. |
| Cloudflare Tunnel | Outbound remotely-managed cloudflared tunnel with root-only token file; ingress hosts configured in Cloudflare. |
| Multi-WAN | Two or more priority-ranked uplinks, explicit activation, gateway checks, periodic failover, alternate-WAN SNAT and route rollback. |
| mDNS Repeater | Avahi IPv4 reflector, selected LAN interfaces, WAN guard and existing-config backup. |
| Captive Portal | openNDS guest-interface gateway, managed listener and NAT hook reinitialization after LiteFW firewall reload. |
| BGP / FRRouting | ASN, router ID, IPv4 neighbors, explicit advertised networks, FRR syntax dry run, inbound-deny and outbound-prefix policy. |

### Alpine deployment caveats

Optional packages use the supported Alpine 3.24 main/community repositories
where available. Tailscale uses native tailscale and tailscale-openrc packages.
Cloudflare Tunnel uses a SHA-256-verified vendor release, and openNDS uses a
pinned verified source archive. No Alpine edge/testing repository is enabled.

Tailscale is disabled until explicitly installed, configured and connected.
Tailnet authentication uses a temporary root-only file; LiteFW never persists
a plaintext Tailscale auth key. Tailnet DNS takeover, exit-node advertising
and Tailscale-managed netfilter rules are disabled. Traffic permissions on
tailscale0 and subnet routing must use LiteFW firewall controls.

GeoIP uses optional IPv4 country feeds. Multi-WAN provides prioritized
failover, not weighted load balancing. BGP requires explicit neighbors
and advertised prefixes.

### Telemetry management

System > Telemetry provides authenticated Prometheus text metrics at
`/api/telemetry/metrics` and optional OTLP/HTTP JSON pushes to an HTTPS
`/v1/metrics` endpoint. Export is opt-in and uses the existing LAN-only
management interface; bearer tokens are root-only and never returned.
There is no centralized log storage, ACME/HAProxy, or DNS filtering module.

`tests/addons-contract-test.sh` covers eight module contracts, valid and
invalid configuration fixtures, and telemetry formats. The headless browser
smoke checks each optional module page and the telemetry admin view.

### Disposable Alpine network behavioral simulations

Run the tests/simulations.sh script in an isolated Alpine container to test
multi-WAN failover, real FRRouting/BIRD BGP sessions, GeoIP kernel IP-set
filtering, WireGuard peer handshakes and protected Cloudflare credentials.
The tests never change the host appliance network.

The tests/modules-ux-integration.sh suite includes WireGuard peer management
and native Tailscale package and configuration tests. Tailscale Connect is
tested with a simulated CLI and synthetic auth keys, without joining a real
tailnet. Production routing and tailnet enrollment require separate testing.

### 2.2.21 module administration improvements

GeoIP now uses a searchable ISO-3166 country/territory picker with A-Z groups,
multi-select checkboxes, clear/select-visible controls and separate save,
CIDR refresh and activation actions. Configuration supports up to 100 codes.
WireGuard generates protected server/client keys and supports peer
management and downloadable client profiles. Multi-WAN uplinks are staged
before activation; BGP settings and neighbors have dedicated controls.
Tailscale has subnet routing settings and explicit connection controls.

These UX paths are covered by headless Chrome and additional disposable
Alpine integration tests: `tests/modules-ux-integration.sh`.

### 2.2.22 live appliance installation correction

The LiteFW control process intentionally uses a restricted PATH that excludes
`/usr/local/bin`. Optional Cloudflare Tunnel and openNDS binaries
are verified and installed there; module detection now checks those absolute
locations without broadening the root command search path.
`tests/vendor-install-alpine.sh` explicitly runs `installed` checks under the
production restricted PATH before and after removal. This defect was caught
by real appliance installation on 10.0.1.199, not by the initial container
smoke tests.

### 2.2.24 connectivity focus

Removed packet inspection engines from the module catalog, UI, API operations
and tests. Legacy modules are no longer enumerated by the API after an upgrade,
even when their old module directories are present. Existing installed
system packages/services are not automatically uninstalled, avoiding
unexpected service changes. Unrelated network and VPN settings are preserved.
GitHub release retention now begins at v2.2.23.
