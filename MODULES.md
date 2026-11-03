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

## Optional security, routing, VPN and network modules (2.2.19)

All modules ship in the tracked runtime manifest and remain off until explicitly
installed, configured, and started. An installed status verifies required
native packages, executable, and (when appropriate) OpenRC service.

| Module | Implementation |
| --- | --- |
| Suricata IDS/IPS | Native Suricata/OpenRC, interface selection, IDS capture or explicit IPS NFQUEUE, manual signature updates. |
| GeoIP Blocking | HTTPS IPdeny aggregated IPv4 country feeds, atomic ipset updates, generated LiteFW INPUT/FORWARD block rules. |
| CrowdSec | Local CrowdSec engine, LAPI ban decisions synchronized to ipset, LiteFW-owned INPUT/FORWARD block rules and cron. |
| WireGuard | wg-quick with protected private key, peer configuration, UDP firewall rule, OpenRC start/stop and boot persistence. |
| Cloudflare Tunnel | Outbound remotely-managed cloudflared tunnel with root-only token file; ingress hosts configured in Cloudflare. |
| Multi-WAN | Two or more priority-ranked uplinks, explicit activation, gateway checks, periodic failover, alternate-WAN SNAT and route rollback. |
| mDNS Repeater | Avahi IPv4 reflector, selected LAN interfaces, WAN guard and existing-config backup. |
| Captive Portal | openNDS guest-interface gateway, managed listener and NAT hook reinitialization after LiteFW firewall reload. |
| BGP / FRRouting | ASN, router ID, IPv4 neighbors, explicit advertised networks, FRR syntax dry run, inbound-deny and outbound-prefix policy. |

### Alpine deployment caveats

Do **not** enable Alpine edge/testing globally. The Alpine 3.24
main/community repositories contain WireGuard, Suricata, Avahi and FRR.
The optional Cloudflare Tunnel now installs the pinned official cloudflared
2026.10.7 static Linux binary with a verified SHA256; CrowdSec installs the
official v1.8.2 static Linux release with verified SHA256 and an OpenRC
service; openNDS is built from the verified 11.0.0 source archive with Alpine
build tools that are removed afterward. The source-based installer path is
verified by `tests/vendor-install-alpine.sh` with actual Alpine 3.24 container
installation and removal; it does not add untrusted APK repositories.

GeoIP lists and CrowdSec remediation are IPv4 only for this version.
Multi-WAN provides prioritized failover, not weighted load balancing or
policy routing. Captive portal and IPS require packet-path validation.
BGP is deliberately conservative: learned routes default deny and only
named IPv4 networks can be advertised. This code has passed source, API,
headless UI, and existing firewall regression tests but has not yet
passed a full Alpine VM/live-service integration run.

### Telemetry management

System > Telemetry provides authenticated Prometheus text metrics at
`/api/telemetry/metrics` and optional OTLP/HTTP JSON pushes to an HTTPS
`/v1/metrics` endpoint. Export is opt-in and uses the existing LAN-only
management interface; bearer tokens are root-only and never returned.
There is no centralized log storage, ACME/HAProxy, or DNS filtering module.

`tests/addons-contract-test.sh` covers nine module contracts, valid and
invalid configuration fixtures, and telemetry formats. The headless browser
smoke checks each optional module page and the telemetry admin view.

### Disposable Alpine network behavioral simulations

Run the same suite enforced by the appliance and runtime CI workflows:

    ./tests/simulations.sh

The runner uses a disposable privileged **Alpine 3.24 Docker container** with
its own network namespace, veth pairs, BIRD and FRRouting, and the actual
Suricata NFQUEUE engine. It does not change networking, rules or routes on
the host LiteFW appliance. The test refuses to execute its inner scripts
outside Docker, and failures return nonzero so CI blocks the build.

The fail-closed CI assertions cover:

- **Multi-WAN:** original default route unchanged while disabled; reachable
  primary selected; simulated upstream failure switches to backup; no-healthy-
  WAN reports failure without replacing the last route; preferred WAN returns;
  backup SNAT enabled only for configured alternate uplinks; original route
  restored.
- **Suricata IDS/IPS:** synthetic ICMP traffic crosses two isolated network
  namespaces; IDS detects but does not block; real NFQUEUE IPS drops matching
  packets; the module emits the queue rule; when Suricata stops, --queue-bypass
  preserves connectivity.
- **BGP:** the LiteFW-generated FRR configuration dry-runs; a real BIRD router
  establishes an external BGP session; the explicitly configured prefix is
  received at the peer; an unexpected prefix exported by the peer is rejected;
  session loss and recovery reconverge.
- **GeoIP/CrowdSec:** deterministic offline threat-source fixtures populate
  actual kernel ipsets; rules block forwarded traffic; invalid/non-ban records
  do not add entries; feed or LAPI failure preserves previously loaded bans.
- **WireGuard:** generated native configuration produces an encrypted tunnel
  between two kernel interfaces; ICMP crosses the encrypted link; handshake
  timestamps and UDP firewall rule are present; secrets are not returned or
  removed by a blank edit; invalid CIDRs are rejected.
- **Cloudflare/mDNS/captive:** native root-only token storage and masked API
  output, token retention on a blank edit, WAN exclusions, reflector interface
  selection and guest interface selection.

Coverage limitations: CrowdSec and GeoIP use offline, deterministic *source*
fixtures, while ipset/iptables are real; BIRD is a real BGP peer but not an
upstream ISP; Suricata itself runs with the production argument modes but
without an OpenRC booted appliance; the WireGuard underlay uses isolated
loopback sockets. Cloudflare publishing, live CrowdSec community enrollment,
Avahi multicast discovery across physical VLANs, openNDS guest redirection,
and hardware link-loss scenarios still need dedicated appliance/integration
testing. These tests are **not** a guarantee of production readiness.


### 2.2.21 module administration improvements

GeoIP now uses a searchable ISO-3166 country/territory picker with A-Z groups,
multi-select checkboxes, clear/select-visible controls and separate save,
CIDR refresh and activation actions. Configuration supports up to 100 codes.
Suricata has source list management, uploaded .rules imports, individual SID
toggles, source enable/disable, import/export, HTTPS refresh, and native
Suricata validation of candidate rules. Rule changes are staged and require
an explicit engine restart. WireGuard now generates protected server and
client keys, provides individual peer add/edit/enable/delete controls, and
downloads authenticated client profiles with private keys never included in
a normal snapshot. Multi-WAN uplinks are staged together before saving.
BGP settings and peers are edited through dedicated controls, not raw JSON.

These UX paths are covered by headless Chrome and additional disposable
Alpine integration tests: `tests/modules-ux-integration.sh`.
