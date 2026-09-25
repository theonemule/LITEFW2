# LiteFWM — Lite Firewall Manager

A small firewall appliance for Alpine Linux, in the spirit of pfSense/IPFire but
as light as possible: Bash, iproute2, iptables, dnsmasq, lighttpd and a static
web UI. LiteFWM **owns** the host's networking — install it on a dedicated
Alpine machine.

## What it does

* **Layer 2** — bridges (optionally VLAN-aware), 802.1Q VLAN interfaces on NICs
  or bridges, per-port PVID/tagged VLANs, MTU. Putting an addressed NIC into a
  bridge moves its IP identity (addresses, MAC, DHCP client, routes, role, DHCP
  server, firewall references) onto the bridge without dropping the session;
  deleting the bridge hands it back.
* **Layer 3 segments** — static / DHCP-client / no address per interface, a name
  (LAN, DMZ, IoT, …) and a role: exactly one **WAN** (default route, outbound
  masquerade) and any number of **LAN** segments.
* **DHCP & DNS** — a dnsmasq DHCP server per LAN segment (range, lease time,
  gateway, DNS, domain, NTP), a live lease list with one-click **Make static**
  (lease → MAC reservation, optional hostname), local domain, upstream servers
  and host records.
* **Firewall** — default deny. Built in: replies to allowed traffic, web UI/SSH
  (optionally limited to chosen segments), DNS/DHCP/ping from LANs to the
  firewall. Ordered allow/block/reject rules between segments, to the internet
  or to the firewall, matching interface, IP/CIDR, protocol and ports.
* **Port forwards** — destination NAT (tcp, udp or both, port ranges, optional
  source restriction); forwarded traffic is allowed automatically. Outbound NAT
  is implicit on the WAN.

## State model

There is no LiteFWM configuration store. The UI shows what the kernel and the
native service files say *now*; **Apply** changes the machine immediately and
the UI re-reads it. After each change LiteFWM rewrites the native boot files
(`/etc/network/interfaces`, `/etc/iptables/rules-save`, `/etc/dnsmasq.d`) from
the live system so the same state comes back after a reboot. See ARCHITECTURE.md.

## Install

    apk add git && git clone <repo> && cd litefwm
    sudo ./install.sh [--port 80] [--admin-user admin]

The running network is adopted as-is: the interface with the default route
becomes the WAN, the firewall starts in default-deny with the web UI and SSH
reachable. The generated admin password is printed once.

## CLI

    lfwctl state                 # live state as JSON
    lfwctl ops                   # list operations
    lfwctl op segment.set '{"interface":"eth1","role":"lan","label":"LAN","mode":"static","addresses":["192.168.10.1/24"]}'

The web UI is a thin client of the same operations (`POST /api/op/NAME`).

## Tests

`tests/lab.sh up|test|ui|down` builds a Docker lab (ISP router, the appliance
with three NICs, a LAN client and a VLAN-trunk client), then runs ~100 end-to-end
checks through the HTTP API — including real DHCP, NAT, port forwards, a live
NIC-into-bridge migration under ping, and a simulated reboot that must restore
an identical state — plus a headless-Chrome run through the UI forms.
