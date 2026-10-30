# LiteFWM architecture

## Rule: the machine is the only copy

| What                  | Read from (live)                          | Persisted to (boot)            |
|-----------------------|-------------------------------------------|--------------------------------|
| links, bridges, VLANs, addresses, routes | `ip -j`, `bridge -j`, sysfs | `/etc/network/interfaces` (ifupdown-ng), regenerated |
| segment role / name   | interface alias `lfw:role=…;name=…` (kernel) | `post-up ip link set … alias` |
| DHCP client           | running `udhcpc` pid files                | `inet dhcp` stanza             |
| firewall / NAT        | `iptables -S` of the LFW_* chains         | `/etc/iptables/rules-save`     |
| DHCP server, DNS      | dnsmasq's own files in `/etc/dnsmasq.d`   | same files (native config)     |
| optional BIND DNS     | `/etc/bind/named.conf`, `/var/bind/litefwm` | same files (native config)   |
| optional OpenVPN      | `/etc/openvpn/litefwm.conf`, PKI, live TUN interface | same native OpenVPN files; TUN is service-owned |
| optional Dynamic DNS  | `/etc/inadyn/inadyn.conf`, OpenRC state     | same file (native config)    |
| reservations          | `/etc/dnsmasq.hosts.d/<mac>` (dhcp-hostsdir) | same                        |
| leases                | `/var/lib/misc/dnsmasq.leases`            | —                              |
| management port, SSH  | lighttpd conf, sshd_config, running sshd  | same                           |

Every operation changes the kernel/service first, then serialises the result.
Nothing is ever loaded *from* a LiteFWM file into the machine.

## Components

* `bin/lfwctl` — entry point: `get RESOURCE [ID]` for feature-scoped live reads,
  `op NAME` for one change (`{ok, warnings, result|error}` out, serialised by a
  lock), and compatibility `state` for older clients.
* `lib/net.sh` — interfaces, bridges, VLANs, segments, `l3_move` (identity
  migration between interfaces); `inventory.jq` builds the model from `ip -j`,
  `persist.jq` renders ifupdown-ng stanzas from it.
* `lib/fw.sh` — iptables. Each change snapshots the user chains from the kernel,
  edits them, loads the whole ruleset atomically with `iptables-restore`, then
  `iptables-save`s it. Derived chains (LFW_SVC, LFW_MOD, LFW_SNAT, LFW_MGMT) are
  regenerated from live roles/services on every change. `LFW_MOD` contains only
  narrow service openings contributed by installed modules; VPN forwarding still
  requires ordinary user firewall rules. Rules carry `lfw:<id> <description>`
  comments; foreign rules are shown read-only. `fwparse.awk` parses `iptables -S`.
* `lib/dhcp.sh` — dnsmasq DHCP servers, leases, reservations, DNS. Config is
  validated with `dnsmasq --test` before it takes effect and rolled back if rejected.
* `lib/sys.sh` — hostname, management port/access with lock-out protection,
  SSH, admin password, diagnostics.
* `lib/modules.sh` and `modules/` — package-on-demand module catalog and native
  service adapters. Installed/configured/running state is discovered from Alpine
  packages, OpenRC and each service's files. There is no module registry. BIND
  disables only dnsmasq's port-53 listener, leaving DHCP active. OpenVPN owns its
  TUN lifecycle; LiteFWM classifies the live TUN as `vpn` for firewall selection
  but excludes it from network persistence.
* `cgi/api.cgi` — lighttpd CGI behind basic auth; runs `sudo lfwctl`. Reads and
  mutations are resource-scoped (`/api/overview`, `/api/interfaces`,
  `/api/firewall`, `/api/port-forwards`, `/api/dhcp`, `/api/dns`,
  `/api/modules/ID`, `/api/system`). `/api/overview` is a dashboard summary read;
  feature pages continue to use their own endpoints.
  Changes need POST plus the `X-LiteFWM: 1` header (CSRF guard). Legacy
  `/api/state` and `/api/op/NAME` are compatibility routes, not UI dependencies.
* `www/` — static single-page UI (Bootstrap 5, no build step, strict CSP). A page
  fetches only its resource dependencies and independent reads run concurrently;
  module snapshots are loaded only for installed modules that need them.

## Firewall layout

    filter INPUT   DROP : lo, established, invalid→drop, DHCP replies, LFW_MGMT, LFW_SVC, LFW_MOD, LFW_IN
    filter FORWARD DROP : established, invalid→drop, ctstate DNAT (port forwards), LFW_FWD
    nat PREROUTING      : LFW_DNAT (port forwards)
    nat POSTROUTING     : LFW_SNAT (masquerade out of the WAN)
