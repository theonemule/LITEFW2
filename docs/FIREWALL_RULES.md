## Unified firewall rule API

The GET /api/firewall response provides one ordered firewall.rules array,
including both host and network traffic. Each rule has an action, protocol,
description and structured source and destination endpoints. Example:


    {
      "id": "1234abcd",
      "action": "drop",
      "proto": "tcp",
      "description": "Block office SMTP",
      "source": {
        "scope": "interface",
        "interface": "eth1",
        "address": "192.168.10.10-192.168.10.40",
        "ports": "1024-65535"
      },
      "destination": {
        "scope": "wan",
        "interface": "",
        "address": "",
        "ports": "25,465"
      }
    }

For POST /api/firewall/rules/add, send an equivalent object without an id.
For /update, include the existing id. Actions: accept (allow),
drop (silently block), reject. Protocols: any, tcp, udp, icmp.

Endpoint scopes: any, wan, interface (requires a real interface name),
host (the local firewall). Traffic to host uses INPUT, traffic from host
uses OUTPUT, and traffic passing through uses FORWARD. Host-to-host is not
supported: loopback is handled by the kernel. Each endpoint may optionally
specify an IPv4 address, CIDR, inclusive IPv4 range, or up to 16 address
expressions. Ports for TCP/UDP may be individual, inclusive ranges, or
comma-separated lists of up to 15.

Legacy fields chain, in, out, src, dst, srcPorts, and ports remain accepted
for compatibility. New callers should use structured source and destination.
The response also includes legacy flat fields so existing clients keep
working. The raw field is for compatibility with imported/unmanaged rules;
the plain-language UI never displays packet-filter syntax.

POST /api/firewall/batch stages the complete rules array in the operator's
chosen order plus NAT forwards, using baseline to detect concurrent edits.
Existing entries include origin (their baseline index), id, and changed
flags; new entries have origin:-1 and changed:true. The response includes
a token. POST this token to /api/firewall/confirm within 120 seconds, or the
prior live and boot rules are restored. Native unmanaged rules remain read-only
and preserved when reordered.

The single UI ordering is persisted in native nftables metadata. First-match
evaluation occurs in the relevant INPUT, FORWARD or OUTPUT kernel packet
path; global display order between distinct packet paths does not change
their evaluation. Protected LAN-only management web and established replies
precede custom policy; user forward deny rules precede the automatic permit
for destination-NAT traffic. Published services are NAT operations in their
own API, not a second traffic-policy list.
