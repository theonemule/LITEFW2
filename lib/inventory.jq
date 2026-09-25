# Build the interface model from live kernel JSON.
# Inputs: $L (ip -d -j link), $A (ip -4 -j addr), $R (ip -4 -j route show table main),
#         $V (bridge -j vlan show), $D (array of interfaces with a running DHCP client)
def has_flag($l; $f): any(($l.flags // [])[]; . == $f);
def kindof($l):
  ($l.linkinfo.info_kind // "") as $k |
  if $l.ifname == "lo" then "loopback"
  elif $k == "bridge" then "bridge"
  elif $k == "vlan" then "vlan"
  elif ($k == "" or $k == "veth") and (($l.link_type // "") == "ether") then "physical"
  else "other" end;
def meta($a):
  if (($a // "") | startswith("lfw:")) then
    ($a[4:] | split(";") | map(select(contains("=")) | split("=") | {key: .[0], value: (.[1:] | join("="))}) | from_entries)
  else {} end;
def vlan_entries($name):
  [ $V[]? | select(.ifname == $name) | .vlans[]? |
    . as $v | range($v.vlan; (($v.vlanEnd // $v.vlan) + 1)) |
    { vid: ., pvid: any(($v.flags // [])[]; . == "PVID"),
      untagged: any(($v.flags // [])[]; . == "Egress Untagged") } ];

[ $L[] as $l | kindof($l) as $kind | select($kind != "loopback") |
  ([ $A[]? | select(.ifname == $l.ifname) | .addr_info[]? |
     select(.family == "inet" and .scope == "global") | "\(.local)/\(.prefixlen)" ]) as $ips |
  ([ $R[]? | select(.dev == $l.ifname and .dst == "default") ][0]) as $def |
  meta($l.ifalias) as $m |
  ([ $L[] | select((.master // "") == $l.ifname) | .ifname ]) as $members |
  {
    name: $l.ifname,
    kind: $kind,
    mac: ($l.address // ""),
    mtu: $l.mtu,
    up: has_flag($l; "UP"),
    carrier: has_flag($l; "LOWER_UP"),
    oper: ($l.operstate // "UNKNOWN"),
    master: ($l.master // null),
    members: $members,
    parent: (if $kind == "vlan" then ($l.link // null) else null end),
    vid: (if $kind == "vlan" then $l.linkinfo.info_data.id else null end),
    vlanFiltering: (if $kind == "bridge" then (($l.linkinfo.info_data.vlan_filtering // 0) == 1) else false end),
    bridgeVlans: (if $kind == "bridge" then
        ([ { port: $l.ifname, self: true, vlans: vlan_entries($l.ifname) } ] +
         [ $members[] as $p | { port: $p, self: false, vlans: vlan_entries($p) } ])
      else [] end),
    role: ($m.role // "none"),
    label: ($m.name // ""),
    mode: (if any($D[]; . == $l.ifname) then "dhcp" elif ($ips | length) > 0 then "static" else "none" end),
    addresses: $ips,
    gateway: (if $def then ($def.gateway // "") else "" end)
  }
]
