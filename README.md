# LiteFWM

LiteFWM, short for Lite Firewall Manager, is a small Alpine Linux firewall and
network appliance manager. It follows the same general philosophy as LiteVMM
and Light Edge: use common Linux components, keep the control plane simple, and
put a thin shell/API layer behind a Bootstrap web interface.

The project is source-only in this workspace. install.sh is intended to run
later on a dedicated Alpine Linux VM or physical appliance.

## Core stack

- Alpine Linux target
- iptables for stateful firewall policy and IPv4 NAT
- iproute2 for interfaces, bridges, and VLANs
- dnsmasq for DHCP and basic DNS forwarding
- lighttpd for the management UI
- POSIX shell control scripts
- CGI JSON API
- Bootstrap single-page management UI
- tcpdump for packet capture
- OpenRC for boot persistence

No Python, Node.js, application server, or database is required on the target.

## Core capabilities

### Network segments

A segment is the main configuration unit. It can represent a physical
interface, a Linux bridge with one or more members, or an 802.1Q VLAN on a
parent interface or bridge.

Each segment has its own address, MTU, DHCP settings, reservations, and
management-access flag. One static segment may also define the appliance default gateway.

### DHCP

DHCP is configured per segment. LiteFWM renders a dnsmasq configuration from
the staged JSON model.

Supported settings include pool start and end, lease duration, gateway option,
DNS server options, static MAC/IP reservations, and promotion of a currently
leased address into a reservation.

The promotion workflow reads the live dnsmasq lease database, keeps the current
IP address, and writes it back as a persistent reservation for that MAC address.

### Firewall

Firewall rules are ordered explicitly and evaluated top to bottom after
LiteFWM's built-in state rules.

Built-in behavior includes loopback acceptance, established and related traffic
acceptance, ICMP, and management-port rules. Configured rules then follow in
explicit order and the chain defaults apply last.

Rule fields include INPUT, OUTPUT, or FORWARD, inbound and outbound segment,
TCP/UDP/ICMP/any protocol, source and destination CIDR, source and destination
port, action, enabled state, description, and position.

### NAT

LiteFWM supports the three common IPv4 NAT patterns.

- Masquerade for dynamic outbound NAT
- SNAT for explicit translated source addresses
- DNAT for inbound port forwarding

DNAT changes the destination only. Forwarding permission remains an explicit
firewall rule, which keeps NAT and security policy separate.

### Monitoring and diagnostics

The base project includes interface state and addressing, RX/TX byte and packet
counters, conntrack count, load and memory overview, recent firewall log
retrieval, and tcpdump captures with a five-minute safety cap.

### Optional modules

The base appliance stays intentionally small. The module manager can install or
remove these Alpine packages on demand.

- OpenVPN
- Tailscale
- BIND DNS
- Squid
- Snort
- HAProxy

Module packages are not installed by the base installer. Module state is stored
in the LiteFWM configuration, and a module-specific directory is reserved under
/etc/litefwm/modules/<module> when installed.

The v0.1 module manager handles package lifecycle and enablement state. Rich
service-specific editors for OpenVPN profiles, BIND zones, Squid ACLs, Snort
policies, Tailscale enrollment, and HAProxy frontends/backends are deliberately
kept outside the core firewall model and can be added as independent module
controllers.

## Configuration model

The canonical staged configuration is:

    /etc/litefwm/config.json

The installer starts from etc/config.json.

The management UI edits the staged configuration. Saving does not immediately
change live networking.

Apply flow:

1. Validate the configuration
2. Snapshot the previous configuration
3. Render network commands
4. Render DHCP configuration
5. Render iptables rules
6. Render lighttpd management configuration
7. Apply network changes
8. Apply DHCP state
9. Atomically load iptables through iptables-restore
10. Update lighttpd only if its generated configuration changed

Generated files live under:

    /var/lib/litefwm/generated

The previous iptables ruleset and previous staged configuration are retained for
rollback.

## Management access safety

A fresh configuration has management allowAny set to true. That intentionally
leaves the management port reachable from any interface until an administrator
explicitly selects trusted management segments and disables allowAny.

Once restricted, LiteFWM emits management-port firewall rules only for the
selected segment devices.

## Web/API security

The management service uses HTTP Basic Authentication through lighttpd.

lighttpd stays unprivileged. CGI does not receive a general root shell. Mutating
API requests call one root broker, apictl, through a dedicated sudo rule. The
broker exposes a fixed command set and validates module names and configuration
before making changes.

Mutating browser requests must also send the same-origin X-LiteFWM-Request
guard header.

The first installer-generated password is printed once during installation and
should be replaced immediately with:

    htpasswd /etc/litefwm/htpasswd admin

TLS is not part of the v0.1 baseline yet. It should be added before exposing the
management service outside a trusted management network.

## Install on an Alpine target

Copy or clone the project onto the dedicated Alpine VM, then run:

    sudo ./install.sh

Optional installer flags:

    sudo ./install.sh --port 8080 --admin-user admin
    sudo ./install.sh --no-start

The installer validates Alpine, installs only the base dependencies, installs
the shell controllers, CGI API, and SPA, creates Basic Auth credentials,
installs the constrained sudo rule, enables IP forwarding, installs the OpenRC
boot service, and starts the management web server unless --no-start is used.

It does not create WAN/LAN segments or apply custom NAT/firewall rules.

## CLI

    configctl show
    configctl validate
    configctl snapshot

    netctl render
    netctl status

    dhcpctl render
    dhcpctl leases
    dhcpctl reserve-lease lan 02:00:00:00:00:50 server

    firewallctl render
    firewallctl check
    firewallctl show
    firewallctl rollback

    modulectl list
    modulectl install openvpn
    modulectl install tailscale
    modulectl install bind
    modulectl install squid
    modulectl install snort
    modulectl install haproxy

    capturectl start lan 30
    capturectl list

    metricsctl
    logctl firewall 200
    diagctl lookup example.com
    diagctl ping 192.168.10.1
    diagctl route 8.8.8.8

    fwmctl validate
    fwmctl render
    fwmctl apply
    fwmctl rollback

## Project layout

    bin/          appliance control commands
    cgi/          shell CGI JSON API
    etc/          initial configuration
    lib/          shared shell helpers
    lighttpd/     web server template
    openrc/       target boot service
    tests/        source-only validation and render tests
    www/          Bootstrap SPA and vendored Bootstrap assets
    install.sh    target-Alpine installer

## Tests

The tests intentionally do not apply networking or firewall state.

    ./tests/syntax-test.sh
    ./tests/render-test.sh
    ./tests/security-validation-test.sh

render-test.sh uses a temporary state directory and a realistic topology with
WAN, LAN bridge, VLAN, DHCP, reservation, masquerade, and DNAT.

## v0.1 scope

The current core policy engine is IPv4-first. IPv6 filtering/NAT, DHCPv6/router
advertisements, multi-WAN policy routing, high availability, certificate
management, and rich optional-module configuration are not part of the first
baseline.

Those can be layered in without changing the central segment/rule/NAT model.
