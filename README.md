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
  (LAN, DMZ, IoT, …) and a role: exactly one **WAN / Internet edge** (default
  route, inbound edge, outbound masquerade) and any number of **LAN / internal**
  routed segments. The UI and console setup make that boundary explicit.
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
* **Logging** — Alpine syslogd remains the source of truth. The System page can
  forward appliance logs to a custom UDP syslog server while optionally keeping
  local `/var/log/messages`; LiteFWM administration events use the `litefwm` tag.
* **Optional modules** — BIND authoritative/recursive DNS, OpenVPN remote-access
  VPN and inadyn Dynamic DNS. The base appliance installs none of those packages.
  Install/remove them from the Modules page; LiteFWM reads their native service
  files and running state instead of keeping a parallel module database. OpenVPN
  TUN interfaces appear live in the interface/firewall model but remain owned by
  OpenVPN rather than `/etc/network/interfaces`.

## State model

There is no LiteFWM configuration store. The UI shows what the kernel and the
native service files say *now*; **Apply** changes the machine immediately and
the UI re-reads it. After each change LiteFWM rewrites the native boot files
(`/etc/network/interfaces`, `/etc/iptables/rules-save`, `/etc/dnsmasq.d`) from
the live system so the same state comes back after a reboot. See ARCHITECTURE.md.

## Install (appliance ISO only)

LiteFW2 is distributed only as an Alpine x86_64 appliance ISO. Download the
ISO and SHA256SUMS from GitHub Releases, verify the checksum, boot it on a
dedicated firewall host or VM, and run `setup-alpine`. The appliance prompts
for WAN and LAN network roles before installing to disk. Back up the target
disk first; installation can erase it. See [APPLIANCE.md](APPLIANCE.md).

The legacy `install.sh` is not a supported product installation method.
Debian and Ubuntu are not supported appliance targets.

`lfw-setup` is installed as a console recovery tool. It reads the live network
and can reassign WAN/LAN roles even when the web UI is unreachable:

    lfw-setup
    lfw-setup show
    lfw-setup wan eth0
    lfw-setup lan eth1 192.168.10.1/24

The firewall starts in default-deny with the web UI and SSH reachable.
Set the web administrator password during `setup-alpine`. The password itself
is never saved as plaintext; only its bcrypt hash is stored. Use `lfw-setup`
from the installed console to reconfigure WAN/LAN interfaces.

Upgrading from the older LiteFWM control plane preserves native BIND, OpenVPN
and inadyn configuration where present, removes the old `/opt/litefwm` control
plane and its owned nftables table, and adopts those services into the v2 live
state model.

## CLI and HTTP API

    lfwctl get interfaces        # one live resource
    lfwctl get firewall          # firewall rules/policy only
    lfwctl get module bind       # one optional module
    lfwctl state                 # compatibility full-state snapshot
    lfwctl ops                   # list operations
    lfwctl op segment.set '{"interface":"eth1","role":"lan","label":"LAN","mode":"static","addresses":["192.168.10.1/24"]}'

The web UI is resource-oriented. It reads only the APIs required by the active
page and requests independent resources in parallel. Primary read endpoints are
`/api/interfaces`, `/api/segments`, `/api/firewall`, `/api/port-forwards`,
`/api/dhcp`, `/api/dns`, `/api/modules`, `/api/modules/ID`, and `/api/system`.
The dashboard uses `/api/overview`, a compact summary endpoint, so initial load
reads shared network/firewall state once instead of launching several redundant
CGI collectors.
Mutations live beneath the same resource, for example
`POST /api/firewall/rules/add`, `POST /api/dhcp/server/set`, and
`POST /api/modules/bind/settings`. `/api/state` and `/api/op/NAME` remain only
as compatibility endpoints for older clients and tests.

## Tests

`tests/lab.sh up|test|ui|down` builds a Docker lab (ISP router, the appliance
with three NICs, a LAN client and a VLAN-trunk client), then runs ~100 end-to-end
checks through the HTTP API — including real DHCP, NAT, port forwards, a live
NIC-into-bridge migration under ping, and a simulated reboot that must restore
an identical state — plus a headless-Chrome run through the UI forms.

`tests/module-contract-test.sh` checks the optional-module contract: packages stay
out of the base install, state remains live/native, BIND and OpenVPN contribute
only derived firewall openings, VPN interfaces are not persisted by ifupdown,
and the UI exposes the expected module controls.

For a routed VM lab, `tests/qemu-lab.sh up` creates a two-NIC LiteFWM Alpine VM
and two 512 MiB Alpine guests behind its private bridge. Each VM uses a sparse
4 GiB qcow2 disk. `tests/qemu-lab.sh test` verifies the LAN, default gateways,
LAN-to-WAN forwarding and masquerade, default-deny WAN input, a real WAN port
forward to the first guest, and every resource API. Use `status` to inspect it
and `down` to remove the bridges, TAPs, namespace and VMs. The harness uses KVM
when `/dev/kvm` is available and otherwise falls back to QEMU TCG.
