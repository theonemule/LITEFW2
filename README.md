# LiteFWM

LiteFWM is a lightweight Alpine Linux firewall/router management UI built with
shell controllers, lighttpd CGI, Bootstrap, iproute2, iptables, dnsmasq, and
OpenRC.

## Live-state design

LiteFWM does not keep a separate configuration database.

The running Linux host is the state. The web UI reads interfaces, addresses,
routes, firewall/NAT rules, DHCP, and service status directly from Linux and
the native services. Changes take effect immediately and are written to the
native configuration files used on reboot.

There is no /etc/litefwm/config.json, no staged configuration, and no Apply
Changes button.

## Networking

The Interfaces page shows the actual Linux links.

- Physical NICs are discovered automatically.
- Bridges can be created empty or with selected members.
- Adding an addressed NIC to a bridge migrates its IPv4/default route to the
  bridge before enslaving the NIC.
- DHCP follows the L3 endpoint when a NIC is moved into a bridge.
- VLAN adapters can use a physical NIC or a bridge as their parent.
- Bridge/VLAN persistence is written to /etc/network/interfaces.

The Network Segments page is derived from live IPv4 assignments. For example,
if eth0 currently has 10.0.1.187/24 from DHCP, that DHCP address appears as a
segment automatically without first creating anything in LiteFWM.

An interface may have multiple static IPv4 addresses.

## DHCP

DHCP-client state comes from the live interface and Alpine networking.

DHCP-server state comes from dnsmasq. LiteFWM writes:

    /etc/dnsmasq.d/litefwm.conf

The DHCP page remains an operational lease/reservation view.

## Firewall and NAT

Firewall and NAT state comes from iptables-save.

Changes are validated, loaded immediately, and persisted to:

    /etc/iptables/rules-save

## Management services

Settings directly manage:

- hostname
- LiteFWM lighttpd port
- SSH enabled/disabled state
- SSH port

The native Lighttpd and SSH configuration files remain authoritative.

## Optional modules

Optional modules are installed only when requested. Their configuration editor
reads and writes the native module files directly, such as:

    /etc/openvpn/openvpn.conf
    /etc/bind/named.conf
    /etc/squid/squid.conf
    /etc/haproxy/haproxy.cfg
    /etc/ddclient/ddclient.conf

No module JSON sidecar is used.

## CLI

The CLI uses the same live model:

    configctl show
    netctl inventory
    netctl interfaces
    netctl segments
    setupctl show

Examples:

    setupctl bridge br0 br0 eth0 true
    setupctl vlan eth0.100 eth0 100
    setupctl segment-static lan br0 192.168.10.1/24
    setupctl segment-dhcp wan eth0

These commands mutate the live system immediately.

## Installation

On a dedicated Alpine host:

    sudo ./install.sh --port 5187 --admin-user blaize

An upgrade removes obsolete LiteFWM JSON/state files from earlier releases.

## Tests

    ./tests/syntax-test.sh
    ./tests/render-test.sh
    ./tests/security-validation-test.sh
    ./tests/migration-test.sh
    ./tests/module-render-test.sh
    ./tests/ddns-render-test.sh

The render test uses mocked Linux live state and validates DHCP discovery,
connectivity-preserving bridge migration, native persistence, and VLAN
parenting without altering the test host.
