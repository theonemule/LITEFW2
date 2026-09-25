# Serialise the live interface model ($I = net inventory) into
# ifupdown-ng syntax for /etc/network/interfaces. Output is raw text.
def kind_of($n): ([$I[] | select(.name == $n) | .kind][0] // "");
def tier:
  if .kind == "physical" then 0
  elif .kind == "vlan" and kind_of(.parent) != "bridge" then 1
  elif .kind == "bridge" then 2
  elif .kind == "vlan" then 3
  else 9 end;
def vlan_cmds:
  .bridgeVlans[] as $p |
  ($p.port) as $port | (if $p.self then " self" else "" end) as $self |
  "    post-up bridge vlan del dev \($port) vid 1\($self) 2>/dev/null || true",
  ($p.vlans[] | "    post-up bridge vlan add dev \($port) vid \(.vid)\(if .pvid then " pvid" else "" end)\(if .untagged then " untagged" else "" end)\($self)");
def stanza:
  (if .mode == "dhcp" then "dhcp" elif .mode == "static" then "static" else "manual" end) as $method |
  "auto \(.name)",
  "iface \(.name) inet \($method)",
  (if .kind == "vlan" then "    vlan-raw-device \(.parent)", "    vlan-id \(.vid)" else empty end),
  (if .kind == "bridge" then
     "    bridge-ports \(if (.members | length) > 0 then (.members | join(" ")) else "none" end)",
     "    hwaddress \(.mac)"
   else empty end),
  (if .mtu != 1500 then "    mtu \(.mtu)" else empty end),
  (if .mode == "dhcp" then "    dhcp-program udhcpc"
   elif .mode == "static" then (.addresses[] | "    address \(.)"),
                               (if .gateway != "" then "    gateway \(.gateway)" else empty end)
   else empty end),
  (if .kind == "bridge" and .vlanFiltering then
     "    post-up ip link set dev \(.name) type bridge vlan_filtering 1", vlan_cmds
   else empty end),
  (if .role != "none" or .label != "" then
     "    post-up ip link set dev \(.name) alias 'lfw:role=\(.role);name=\(.label)'"
   else empty end),
  "";
[ $I[] | select(.kind != "other") ] | sort_by(tier, .name) | .[] | stanza
