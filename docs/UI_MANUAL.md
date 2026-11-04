# LiteFW Administrator Manual

LiteFW is an Alpine firewall/router appliance with a single-page web interface.
Open the management address from a LAN segment, sign in with Basic administrator
credentials, then use the sidebar to navigate without full page reloads.

## Dashboard and navigation
- **Overview** summarizes interfaces, forwarding, services, memory and health.
- **Interfaces** manages Linux devices, VLANs and bridges.
- **Network segments** assigns WAN/LAN roles, addresses and DHCP servers.
- **Firewall & port forwards** edits access rules and NAT using staged
  apply/confirm protection against losing management access.
- **DHCP and DNS** manages reservations, BIND zones, DNSMasq and upstreams.
- **Modules** installs optional services, then configures/starts them separately.
- **System** manages access, updates, logging, diagnostics and API keys.

## First-time management
1. Configure a LAN address and administrator account through the appliance console.
2. Reach the web UI from the LAN. Do not expose it on an untrusted WAN.
3. Configure WAN/LAN and check your default route and DNS resolution.
4. Review firewall rules, stage changes, and confirm before rollback timeout.
5. Install optional modules only when needed. Installation does not start them.

## Modules
LiteFW focuses on network connectivity rather than packet inspection.
GeoIP country blocking remains optional, independently configured and disabled
until explicitly started.

WireGuard manages peers and creates downloadable client profiles for
automatically generated client keys. Cloudflare Tunnel uses an outbound
connector token that is never exposed by API status responses.

Tailscale provides encrypted tailnet connectivity and optional advertised
subnet routes. Installation never joins a tailnet; an explicit Connect action
uses a one-time authentication key, which is never stored by LiteFW.
DNS takeover and Tailscale-owned firewall rules stay disabled, so access
permissions must be configured in LiteFW's firewall.

Multi-WAN provides prioritized failover, not load balancing. BGP/FRRouting
supports configured peers and explicit prefixes. Captive Portal should be
limited to guest LAN interfaces; mDNS reflector to chosen LAN interfaces.

## API keys in System
Open System, then API keys, and choose Create API key. Enter a name, choose
Read only or Administrator permissions, and an expiration period. Copy the
secret: it is shown **only once**.

- Read-only keys can GET resources, but cannot modify configuration.
- Administrator keys can modify API-managed settings, but cannot create or
  revoke keys, change the Basic administrator password, or alter management
  access. Those sensitive operations require Basic credentials.
- Revoke a key in System to invalidate it immediately.

API keys use the X-API-Key request header. Basic credentials continue to
work. Both are sensitive bearer-style credentials: use HTTPS or an encrypted
management tunnel. HTTP over a LAN exposes them to interception.

## Appliance updates and recovery
System > Software updates checks signed-off GitHub release assets and their
SHA-256 manifests before applying the runtime upgrade. Alpine package updates
have separate Check and Upgrade buttons. An in-place upgrade preserves
configuration and creates backups. Keep console/Proxmox access available
for firewall, WAN, BGP and subnet routing work.

## Further references
- [API reference](api.html)
- [CLI manual](cli.html)
- [OpenAPI 3.1 specification](openapi.json)
