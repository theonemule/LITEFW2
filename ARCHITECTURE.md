# LiteFWM Architecture

## Design rule

The JSON configuration is the desired state. The web UI never runs iptables,
iproute2, dnsmasq, or package-management commands directly.

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
        +--> netctl
        +--> dhcpctl
        +--> firewallctl
        +--> webctl
        +--> modulectl
        +--> capturectl
        +--> metricsctl
        +--> logctl

fwmctl apply is the coordinator.

## Desired-state files

    /etc/litefwm/config.json
    /etc/litefwm/htpasswd
    /etc/litefwm/modules/
    /var/lib/litefwm/generated/
    /var/lib/litefwm/captures/
    /var/lib/litefwm/dnsmasq.leases

## Segment to device mapping

- Interface segment maps to its physical interface
- Bridge segment maps to the configured bridge name
- VLAN segment maps to its explicit device or parent.vlanId

The same mapping is used by network creation, management pinning, firewall
rules, NAT rules, DHCP listeners, monitoring, and captures.

## Apply and rollback

The design intentionally separates save from apply.

Saving configuration only replaces the staged JSON after validation.

Applying:

1. Snapshot the previous JSON
2. Snapshot the current iptables rules
3. Render every subsystem
4. Validate generated firewall rules
5. Configure segment devices
6. Update DHCP
7. Atomically load iptables
8. Update the web listener if necessary

firewallctl rollback restores the last iptables snapshot. fwmctl rollback also
restores the previous JSON when available.

Network-interface rollback is not yet transactional in v0.1, so administrators
should preserve a console path while making topology changes.
