#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin"

cat > "$TMP/interfaces" <<'NET'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    udhcpc_opts -r 10.0.1.187
NET

cat > "$TMP/bin/ip" <<'MOCK'
#!/bin/sh
case "$*" in
  "-d -j link show")
    cat <<'JSON'
[
 {"ifindex":1,"ifname":"lo","flags":["LOOPBACK","UP"],"mtu":65536,"operstate":"UNKNOWN","link_type":"loopback","address":"00:00:00:00:00:00"},
 {"ifindex":2,"ifname":"eth0","flags":["BROADCAST","UP","LOWER_UP"],"mtu":1500,"operstate":"UP","link_type":"ether","address":"00:15:5d:01:33:29"}
]
JSON
    ;;
  "-4 -j addr show")
    cat <<'JSON'
[
 {"ifindex":1,"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8,"scope":"host"}]},
 {"ifindex":2,"ifname":"eth0","addr_info":[{"family":"inet","local":"10.0.1.187","prefixlen":24,"scope":"global","dynamic":true}]}
]
JSON
    ;;
  "-4 -j route show table main")
    echo '[{"dst":"default","gateway":"10.0.1.1","dev":"eth0"},{"dst":"10.0.1.0/24","dev":"eth0"}]'
    ;;
  "-4 -j addr show dev eth0")
    echo '[{"ifindex":2,"ifname":"eth0","addr_info":[{"family":"inet","local":"10.0.1.187","prefixlen":24,"scope":"global","dynamic":true}]}]'
    ;;
  "-4 -j addr show dev br0"|"-4 -j addr show dev eth0.100")
    echo '[]'
    ;;
  "-4 -j route show default dev eth0")
    echo '[{"dst":"default","gateway":"10.0.1.1","dev":"eth0"}]'
    ;;
  "-4 -j route show default dev br0"|"-4 -j route show default dev eth0.100")
    echo '[]'
    ;;
  "-j link show dev eth0")
    echo '[{"ifindex":2,"ifname":"eth0"}]'
    ;;
  "-j link show dev br0"|"-j link show dev eth0.100")
    echo '[]'
    ;;
  "-j link show")
    echo '[{"ifindex":1,"ifname":"lo"},{"ifindex":2,"ifname":"eth0"}]'
    ;;
  "link show dev eth0") exit 0;;
  "link show dev br0"|"link show dev eth0.100") exit 1;;
  *) echo "unexpected ip call: $*" >&2; exit 1;;
esac
MOCK
chmod +x "$TMP/bin/ip"

export PATH="$TMP/bin:$PATH"
export LITEFWM_INTERFACES="$TMP/interfaces"
export LITEFWM_RUN="$TMP/run"
export LITEFWM_DRY_RUN=1

segments=$("$ROOT/bin/netctl" segments)
printf '%s' "$segments" | jq -e '
  length==1 and
  .[0].interface=="eth0" and
  .[0].addressMode=="dhcp" and
  .[0].currentAddress=="10.0.1.187/24" and
  .[0].gateway=="10.0.1.1"
' >/dev/null

interfaces=$("$ROOT/bin/netctl" interfaces)

jq -n --argjson i "$interfaces" --argjson s "$segments" '
  {
    interfaces:($i + [{
      id:"br0",name:"br0",device:"br0",type:"bridge",kind:"bridge",
      managed:true,persistent:true,enabled:true,mtu:1500,
      vlanAware:true,members:["eth0"]
    }]),
    segments:$s
  }
' > "$TMP/bridge.json"

bridge=$("$ROOT/bin/netctl" reconcile "$TMP/bridge.json")
printf '%s
' "$bridge" | grep -Fq '+ ip addr add 10.0.1.187/24 dev br0'
printf '%s
' "$bridge" | grep -Fq '+ ip route replace default via 10.0.1.1 dev br0'
printf '%s
' "$bridge" | grep -Fq '+ ip link set dev eth0 master br0'
printf '%s
' "$bridge" | grep -Fq '+ ip addr del 10.0.1.187/24 dev eth0'
printf '%s
' "$bridge" | grep -Fq '+ udhcpc -i br0 -b -q -r 10.0.1.187'
printf '%s
' "$bridge" | grep -Fq 'iface eth0 inet manual'
printf '%s
' "$bridge" | grep -Fq 'iface br0 inet dhcp'
printf '%s
' "$bridge" | grep -Fq 'udhcpc_opts -r 10.0.1.187'

jq -n --argjson i "$interfaces" --argjson s "$segments" '
  {
    interfaces:($i + [{
      id:"eth0.100",name:"eth0.100",device:"eth0.100",type:"vlan",kind:"vlan",
      managed:true,persistent:true,enabled:true,mtu:1500,parent:"eth0",vlanId:100,members:[]
    }]),
    segments:$s
  }
' > "$TMP/vlan.json"

vlan=$("$ROOT/bin/netctl" reconcile "$TMP/vlan.json")
printf '%s
' "$vlan" | grep -Fq '+ ip link add link eth0 name eth0.100 type vlan id 100'
printf '%s
' "$vlan" | grep -Fq 'iface eth0.100 inet manual'
printf '%s
' "$vlan" | grep -Fq 'ip link add link eth0 name eth0.100 type vlan id 100'

echo "render-test: PASS"
