# LiteFWM architecture

## Rule: the machine is the only copy

| What                  | Read from (live)                          | Persisted to (boot)            |
|-----------------------|-------------------------------------------|--------------------------------|
| links, bridges, VLANs, addresses, routes | `ip -j`, `bridge -j`, sysfs | `/etc/network/interfaces` (ifupdown-ng), regenerated |
| segment role / name   | interface alias `lfw:role=…;name=…` (kernel) | `post-up ip link set … alias` |
| DHCP client           | running `udhcpc` pid files                | `inet dhcp` stanza             |
| firewall / NAT        | `iptables -S` of the LFW_* chains         | `/etc/iptables/rules-save`     |
| DHCP server, DNS      | dnsmasq's own files in `/etc/dnsmasq.d`   | same files (native config)     |
| reservations          | `/etc/dnsmasq.hosts.d/<mac>` (dhcp-hostsdir) | same                        |
| leases                | `/var/lib/misc/dnsmasq.leases`            | —                              |
| management port, SSH  | lighttpd conf, sshd_config, running sshd  | same                           |

Every operation changes the kernel/service first, then serialises the result.
Nothing is ever loaded *from* a LiteFWM file into the machine.

## Components

* `bin/lfwctl` — entry point: `state` (one JSON snapshot) and `op NAME` (one
  change, JSON in, `{ok, warnings, result|error}` out, serialised by a lock).
* `lib/net.sh` — interfaces, bridges, VLANs, segments, `l3_move` (identity
  migration between interfaces); `inventory.jq` builds the model from `ip -j`,
  `persist.jq` renders ifupdown-ng stanzas from it.
* `lib/fw.sh` — iptables. Each change snapshots the user chains from the kernel,
  edits them, loads the whole ruleset atomically with `iptables-restore`, then
  `iptables-save`s it. Derived chains (LFW_SVC, LFW_SNAT, LFW_MGMT) are
  regenerated from roles on every change. Rules carry `lfw:<id> <description>`
  comments; foreign rules are shown read-only. `fwparse.awk` parses `iptables -S`.
* `lib/dhcp.sh` — dnsmasq DHCP servers, leases, reservations, DNS. Config is
  validated with `dnsmasq --test` before it takes effect and rolled back if rejected.
* `lib/sys.sh` — hostname, management port/access with lock-out protection,
  SSH, admin password, diagnostics.
* `cgi/api.cgi` — lighttpd CGI behind basic auth; runs `sudo lfwctl`. Changes
  need POST plus the `X-LiteFWM: 1` header (CSRF guard).
* `www/` — static single-page UI (Bootstrap 5, no build step, strict CSP).

## Firewall layout

    filter INPUT   DROP : lo, established, invalid→drop, DHCP replies, LFW_MGMT, LFW_SVC, LFW_IN
    filter FORWARD DROP : established, invalid→drop, ctstate DNAT (port forwards), LFW_FWD
    nat PREROUTING      : LFW_DNAT (port forwards)
    nat POSTROUTING     : LFW_SNAT (masquerade out of the WAN)
