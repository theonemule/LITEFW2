# LiteFWM Architecture

## Control path

The JSON configuration is desired state. The SPA never invokes iptables,
iproute2, dnsmasq, or package management directly.

    Bootstrap SPA
        |
        v
    lighttpd + Basic Auth
        |
        v
    shell CGI API
        |
        v
    sudo apictl
        |
        +--> configctl
        +--> setupctl
        +--> netctl
        +--> dhcpctl
        +--> firewallctl
        +--> webctl
        +--> modulectl
        +--> modulecfgctl
        +--> ddnsctl
        +--> capturectl
        +--> metricsctl
        +--> logctl

fwmctl apply is the core coordinator.

## Schema v2

Schema v3 separates interfaces from network segments and makes segments the IP/policy boundary.

An interface is a link-layer endpoint: physical device, Linux bridge, or VLAN
subinterface.

A segment is L3 policy bound to one interface: internal/external classification, static or DHCP-client addressing, gateway, DNS/domain, and DHCP-server policy/reservations. Multiple static segments may share an interface.

Firewall and NAT rules reference segment IDs. They resolve to interface devices
through the same mapping used by DHCP, captures, and management pinning.

## Bridge and VLAN order

Network rendering creates links in dependency order:

1. physical links are brought up and MTU is set
2. bridges are created and VLAN filtering configured
3. VLAN links are created from their configured parent endpoint
4. bridge membership is applied
5. segment addresses and the optional default route are applied

A VLAN can therefore use a bridge as its parent, and a bridge can contain a VLAN
endpoint created earlier in the interface model.

## Firewall baseline

The generated filter table defaults to INPUT DROP, FORWARD DROP, OUTPUT ACCEPT.

Before user rules, LiteFWM installs loopback, established/related, ICMP,
optional SSH, and management INPUT exceptions.

User rules are ordered by explicit position. NAT is generated separately.

## DHCP and BIND integration

dnsmasq owns DHCP leases and reservations. Segment configuration determines the
interface, range, router, DNS, domain, and lease duration.

The DHCP page can reserve a live lease. When BIND is installed and configured,
the same operation may add or replace an A record in the BIND module
configuration and reapply BIND when enabled.

## Optional modules

Package lifecycle is handled by modulectl. Service-specific desired state,
validation, native rendering, and apply behavior are handled by modulecfgctl.
DDNS delegates provider-specific rendering to ddnsctl.

Module state is stored under /etc/litefwm/modules/<module>/. Module
configuration is intentionally separate from the core network/firewall schema.

## Apply and rollback

Saving configuration only updates staged JSON after validation.

Applying:

1. snapshot JSON
2. render all core subsystems
3. snapshot current iptables state
4. configure network endpoints and segment addressing
5. update DHCP
6. atomically load iptables
7. update lighttpd
8. apply installed/enabled optional modules

Firewall rollback is transactional through the previous iptables snapshot.
Network topology rollback is not yet transactional, so console access is
recommended for disruptive topology changes.

## Desired-state paths

    /etc/litefwm/config.json
    /etc/litefwm/htpasswd
    /etc/litefwm/modules/
    /var/lib/litefwm/generated/
    /var/lib/litefwm/captures/
    /var/lib/litefwm/dnsmasq.leases
