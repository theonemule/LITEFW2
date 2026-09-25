# LiteFWM

LiteFWM is a lightweight Alpine Linux firewall and router appliance manager. It
uses iproute2, iptables, dnsmasq, lighttpd, OpenRC, shell controllers, and a
Bootstrap SPA. Python, Node.js, an application server, and a database are not
required on the target.

## Network model

LiteFWM separates link configuration from L3 network configuration.

### Interfaces

The Interfaces page manages reusable network endpoints.

- Physical NICs
- VLAN-aware Linux bridges
- 802.1Q VLAN adapters
- WAN, LAN, or unassigned role metadata
- MTU and enabled state

A bridge can contain physical or VLAN interfaces. A VLAN can use a physical NIC
or a bridge as its parent. For example, bridge br0 can be the parent of
br0.100, and either endpoint can then be bound to a network segment.

A typical routed firewall uses at least two configured endpoints, normally WAN
and LAN. LiteFWM does not enforce that minimum so first-time and lab
configuration can be completed safely.

### Network segments

A network segment is an L3/IP configuration bound to a managed interface.
Multiple static segments may share one interface, which gives that interface
multiple IPv4 addresses/networks. A single DHCP-client segment may also obtain
its address, gateway, and DNS settings from an upstream DHCP server.

Per-segment settings include internal/external firewall classification, static
or DHCP-client addressing, optional default gateway, DNS and local domain,
DHCP-server enablement, pool and lease time, client router/DNS/NTP options,
static reservations, and management access.

## Firewall and NAT

The default policy is INPUT DROP, FORWARD DROP, OUTPUT ACCEPT.

Built-in appliance rules are evaluated before user rules:

- loopback
- established and related traffic
- ICMP to the appliance
- SSH when enabled, default TCP 22
- LiteFWM management, default TCP 5187

Management starts in allowAny mode to avoid first-install lockout. It can be
restricted to selected network segments later.

User firewall rules are ordered explicitly and expressed in network segments.
Internal static segments automatically contribute their subnet match when a
rule does not specify a narrower address.

Outbound NAT is configured as a source segment to an outbound segment. It can
use the outbound address dynamically or a fixed SNAT address. Port forwarding
uses destination NAT on an inbound/external segment. DNAT does not implicitly
create a FORWARD allow rule.

## DHCP and local DNS

DHCP policy is configured on Network Segments. The DHCP page is an operational
view for active leases and reservations.

An active lease can be promoted to a reservation while retaining its current
MAC and IP. If BIND 9 is installed and configured, the reservation dialog can
also publish the hostname as an A record in the configured local zone.

## Optional modules

Optional packages are installed only when requested. Each installed module has
a Configure action in the web UI.

- OpenVPN: server protocol, port, tunnel network, DNS/routes, certificate paths
- Tailscale: enrollment key, hostname, advertised routes, exit node, SSH
- BIND 9: local zone, listeners, recursion networks, forwarders, A records
- Squid: listener, allowed segments, cache size, blocked domains
- Snort: monitored interface, HOME_NET, IDS/IPS mode, config and arguments
- HAProxy: mode, listener, balancing, backend servers
- Dynamic DNS: provider, address source, hostname list, provider credentials

Module configuration is stored separately under:

    /etc/litefwm/modules/<module>/config.json

Secrets such as Tailscale and Dynamic DNS credentials are redacted when read
through the API.

## First-time CLI setup

setupctl exposes the same interface/segment model without requiring the web UI.

Inspect physical links:

    setupctl inventory

Create a simple physical WAN and LAN:

    setupctl physical wan0 eth0 WAN
    setupctl physical lan0 eth1 LAN
    setupctl segment-static lan lan0 192.168.10.1/24 internal "" 192.168.10.1 home.arpa
    setupctl dhcp lan true 192.168.10.100 192.168.10.200 12h

Create a VLAN-aware bridge:

    setupctl physical lanp1 eth1 lan-port-1
    setupctl physical lanp2 eth2 lan-port-2
    setupctl bridge lan br0 lanp1,lanp2 true
    setupctl segment-static lan lan 192.168.10.1/24 internal

Create a VLAN adapter on that bridge:

    setupctl vlan iot-vlan lan 20 br0.20
    setupctl segment-static iot iot-vlan 192.168.20.1/24 internal
    setupctl dhcp iot true 192.168.20.100 192.168.20.199 8h

Restrict the management listener to a segment:

    setupctl management lan 5187
    setupctl ssh true 22

Validate before applying:

    fwmctl validate
    setupctl apply

Topology changes are staged until apply.

## Installation

On a dedicated Alpine target:

    sudo ./install.sh

The default web port is 5187. Options include:

    sudo ./install.sh --port 5187 --admin-user admin
    sudo ./install.sh --no-start

The installer does not invent WAN/LAN addressing or apply a firewall topology.
Configure it through the UI or setupctl, validate it, then apply it.

## Main commands

    configctl show
    configctl validate
    configctl migrate legacy.json

    setupctl inventory
    setupctl show

    netctl inventory
    netctl render

    dhcpctl leases
    dhcpctl reserve-lease SEGMENT MAC HOSTNAME

    firewallctl render
    firewallctl check
    firewallctl rollback

    modulectl list
    modulectl install bind
    modulecfgctl show bind
    modulecfgctl validate bind
    modulecfgctl apply bind

    ddnsctl show
    ddnsctl validate
    ddnsctl apply
    ddnsctl query

    fwmctl validate
    fwmctl render
    fwmctl apply
    fwmctl rollback

## Configuration and apply flow

The canonical desired state is:

    /etc/litefwm/config.json

Saving through the UI only stages configuration. fwmctl apply coordinates
schema validation, previous-config snapshot, network apply, DHCP apply, atomic
iptables load, lighttpd update, and optional-module apply.

Generated files live under /var/lib/litefwm/generated.

## Security notes

The management UI uses HTTP Basic Authentication through lighttpd. CGI remains
unprivileged and reaches a fixed root command broker through a constrained sudo
rule. Mutating browser requests require X-LiteFWM-Request: 1.

The current release is IPv4-first. TLS for the management UI, IPv6,
DHCPv6/router advertisements, multi-WAN policy routing, HA, and transactional
network rollback remain future work.

## Tests

Source tests do not apply host networking or firewall state.

    ./tests/syntax-test.sh
    ./tests/render-test.sh
    ./tests/security-validation-test.sh
    ./tests/migration-test.sh
    ./tests/module-render-test.sh
    ./tests/ddns-render-test.sh
