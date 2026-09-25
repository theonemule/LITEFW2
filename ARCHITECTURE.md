# LiteFWM Architecture

LiteFWM is a live-state management layer for an Alpine Linux firewall/router.

## Core rule

Linux and the native services are the source of truth.

LiteFWM does not maintain a network/firewall configuration database and does
not stage a second desired-state model. The browser receives an ephemeral JSON
snapshot assembled from the running host. A mutation request is reconciled
immediately into the running host and the corresponding native configuration
needed to survive reboot.

There is no /etc/litefwm/config.json and there is no Apply Changes phase.

## Authoritative sources

Networking:

    running: ip link, ip addr, ip route
    persistent: /etc/network/interfaces

Firewall and NAT:

    running: iptables-save
    persistent: /etc/iptables/rules-save

DHCP:

    running: dnsmasq + lease database
    persistent: /etc/dnsmasq.d/litefwm.conf

Management:

    lighttpd: /etc/lighttpd/litefwm.conf
    SSH: /etc/ssh/sshd_config
    hostname: Alpine hostname configuration

Optional modules use their native configuration files, for example BIND,
OpenVPN, Squid, HAProxy, Tailscale/OpenRC, Snort, and ddclient.

## API model

GET requests inspect the host when the request is made.

GET /api/config is a compatibility-shaped live snapshot. It is not backed by a
LiteFWM JSON file.

PUT requests use JSON only as an HTTP request envelope. The request is compared
with a fresh live snapshot and only changed subsystems are reconciled.

After each mutation the UI reloads state from the host.

## Interfaces

The interface page represents actual Linux links.

Physical NICs are discovered automatically. Bridges and VLAN interfaces are
real kernel links, not LiteFWM objects.

A bridge can be created with no members or with physical/VLAN members.

When a live interface that currently owns IPv4/default-route configuration is
added to a bridge, LiteFWM performs the migration in this order:

1. Create and bring up the bridge.
2. Copy the member's current IPv4 address to the bridge.
3. Move the default route to the bridge.
4. Stop DHCP on the member when applicable.
5. Enslave the member to the bridge.
6. Remove the old address from the member.
7. Start DHCP on the bridge and request the previous lease when applicable.
8. Rewrite /etc/network/interfaces to reflect the topology.

This ordering is designed to preserve the active management path while the
layer-2 topology changes.

VLAN adapters can use a physical NIC or bridge as their parent. Their Linux
device name and VLAN ID are persisted directly in Alpine networking.

## Network segments

A segment is a live IPv4 configuration observed on an interface.

A DHCP interface exposes its current leased address, gateway, and DNS. Static
addresses appear directly from ip addr. Multiple static addresses on one
interface appear as multiple segments.

Editing a segment changes the live interface immediately and then rewrites
native Alpine networking.

DHCP-server settings are read from and written to the native dnsmasq
configuration.

## Firewall and NAT

The firewall page reflects the running iptables rules and policies.

Saving firewall or NAT changes validates with iptables-restore, loads them
immediately, and persists the resulting rule set for reboot.

## Modules

Optional modules are discovered from installed packages and OpenRC service
state. Their configuration editor operates on each module's native
configuration file. LiteFWM does not create module JSON sidecars.

## Boot behavior

LiteFWM does not need an OpenRC service to replay application state.

Alpine networking, iptables, dnsmasq, lighttpd, SSH, and optional modules
restore themselves from their native configuration/service setup.
