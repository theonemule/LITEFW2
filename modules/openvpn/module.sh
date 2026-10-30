#!/bin/sh
set -eu
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMMON="$SELF/../../lib/common.sh"
[ -r "$COMMON" ] || COMMON="$SELF/../../common.sh"
[ -r "$COMMON" ] || COMMON=/usr/lib/litefwm/common.sh
. "$COMMON"
COMPAT="$SELF/../../lib/module-compat.sh"
[ -r "$COMPAT" ] || COMPAT="$SELF/../../module-compat.sh"
. "$COMPAT"

CONF=/etc/openvpn/litefwm.conf
PKI=/etc/openvpn/pki
CLIENT_DIR=/etc/openvpn/clients
EASYRSA=/usr/share/easy-rsa/easyrsa

meta(){ jq -n '{id:"openvpn",name:"OpenVPN",description:"Routed remote-access VPN with appliance-managed PKI and downloadable client profiles.",category:"vpn"}'; }
installed(){ command -v openvpn >/dev/null 2>&1 && [ -x "$EASYRSA" ]; }
running(){ command -v rc-service >/dev/null 2>&1 && rc-service openvpn.litefwm status >/dev/null 2>&1; }
setting(){ sed -n "s/^# litefwm:$1=//p" "$CONF" 2>/dev/null | head -1; }
valid_client(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'; }
valid_proto(){ [ "$1" = udp ] || [ "$1" = tcp ]; }

cidr_netmask(){
  cidr=$1; p=${cidr#*/}; ip=${cidr%/*}
  valid_cidr "$cidr" || die "Invalid VPN network"
  case "$p" in
    8) mask=255.0.0.0;; 9) mask=255.128.0.0;; 10) mask=255.192.0.0;; 11) mask=255.224.0.0;;
    12) mask=255.240.0.0;; 13) mask=255.248.0.0;; 14) mask=255.252.0.0;; 15) mask=255.254.0.0;;
    16) mask=255.255.0.0;; 17) mask=255.255.128.0;; 18) mask=255.255.192.0;; 19) mask=255.255.224.0;;
    20) mask=255.255.240.0;; 21) mask=255.255.248.0;; 22) mask=255.255.252.0;; 23) mask=255.255.254.0;;
    24) mask=255.255.255.0;; 25) mask=255.255.255.128;; 26) mask=255.255.255.192;; 27) mask=255.255.255.224;;
    28) mask=255.255.255.240;; 29) mask=255.255.255.248;; 30) mask=255.255.255.252;;
    *) die "VPN network prefix must be /8 through /30";;
  esac
  printf '%s %s\n' "$ip" "$mask"
}
restart_vpn(){
  rc-update add openvpn.litefwm default >/dev/null 2>&1 || true
  if running; then rc-service openvpn.litefwm restart; else rc-service openvpn.litefwm start; fi
}
server_set(){
  require_root
  public=$1; inbound=$2; dev=$3; proto=$4; port=$5; cidr=$6; dns=$7; routes=$8; redirect=$9
  shift 9; c2c=${1:-false}
  valid_dns_name "$public" || valid_ipv4 "$public" || die "Invalid public VPN host"
  [ "$inbound" = wan ] || safe_iface "$inbound" || die "Invalid inbound interface"
  safe_iface "$dev" || die "Invalid VPN interface"
  printf '%s' "$dev" | grep -Eq '^tun[0-9]+$' || die "VPN interface must be tunN"
  valid_proto "$proto" || die "Protocol must be udp or tcp"
  valid_port "$port" || die "Invalid VPN port"
  valid_cidr "$cidr" || die "Invalid VPN network"
  valid_ipv4_csv "$dns" || die "Invalid DNS push list"
  case "$redirect:$c2c" in true:true|true:false|false:true|false:false) ;; *) die "Invalid VPN flags";; esac
  old=$IFS; IFS=,; for r in $routes; do [ -z "$r" ] || valid_cidr "$r" || { IFS=$old; die "Invalid pushed route"; }; done; IFS=$old

  set -- $(cidr_netmask "$cidr"); net=$1; mask=$2
  mkdir -p /etc/openvpn "$CLIENT_DIR"
  tmp=$(mktemp)
  {
    echo "# LiteFWM OpenVPN server"
    echo "# litefwm:public-host=$public"
    echo "# litefwm:inbound-interface=$inbound"
    echo "# litefwm:device=$dev"
    echo "# litefwm:protocol=$proto"
    echo "# litefwm:port=$port"
    echo "# litefwm:network=$cidr"
    echo "# litefwm:dns=$dns"
    echo "# litefwm:routes=$routes"
    echo "# litefwm:redirect-gateway=$redirect"
    echo "# litefwm:client-to-client=$c2c"
    echo "port $port"
    [ "$proto" = udp ] && echo "proto udp" || echo "proto tcp-server"
    echo "dev $dev"
    echo "topology subnet"
    echo "server $net $mask"
    echo "ca $PKI/ca.crt"
    echo "cert $PKI/issued/server.crt"
    echo "key $PKI/private/server.key"
    echo "crl-verify $PKI/crl.pem"
    echo "dh none"
    echo "ecdh-curve prime256v1"
    echo "tls-crypt /etc/openvpn/tls-crypt.key"
    echo "tls-version-min 1.2"
    echo "data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"
    echo "auth SHA256"
    echo "keepalive 10 120"
    echo "persist-key"
    echo "persist-tun"
    echo "status /run/openvpn-litefwm.status 10"
    echo "verb 3"
    [ "$proto" = udp ] && echo "explicit-exit-notify 1"
    [ "$redirect" = true ] && echo 'push "redirect-gateway def1 bypass-dhcp"'
    old=$IFS; IFS=,; for x in $dns; do [ -z "$x" ] || echo "push \"dhcp-option DNS $x\""; done; IFS=$old
    # Do not leave IFS set to comma while parsing cidr_netmask output.
    # That output is space-delimited (network + netmask).
    for x in $(printf '%s' "$routes" | tr ',' ' '); do
      [ -z "$x" ] && continue
      set -- $(cidr_netmask "$x")
      echo "push \"route $1 $2\""
    done
    [ "$c2c" = true ] && echo "client-to-client"
  } > "$tmp"
  mv "$tmp" "$CONF"
  chmod 0600 "$CONF"
  restart_vpn
}
clients_json(){
  [ -r "$PKI/index.txt" ] || { echo '[]'; return; }
  awk -F'\t' '
    $1=="V" || $1=="R" {
      cn=$NF; sub(/^.*CN=/,"",cn); status=($1=="V"?"valid":"revoked")
      print cn "\t" status
    }' "$PKI/index.txt" |
  while IFS="$(printf '\t')" read -r name status; do
    [ "$name" = server ] && continue
    profile=false; [ -r "$CLIENT_DIR/$name.ovpn" ] && profile=true
    jq -n --arg name "$name" --arg status "$status" --argjson profile "$profile" '{name:$name,status:$status,profileAvailable:$profile}'
  done | jq -s .
}
profile_build(){
  name=$1
  valid_client "$name" || die "Invalid client name"
  public=$(setting public-host); proto=$(setting protocol); port=$(setting port); dev=$(setting device)
  [ -n "$public" ] || die "Configure the VPN server first"
  [ -r "$PKI/issued/$name.crt" ] || die "Client certificate not found"
  pproto=udp; [ "$proto" = tcp ] && pproto=tcp-client
  mkdir -p "$CLIENT_DIR"
  {
    echo "client"
    echo "dev ${dev:-tun0}"
    echo "proto $pproto"
    echo "remote $public $port"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "auth-nocache"
    echo "verb 3"
    echo "<ca>"; cat "$PKI/ca.crt"; echo "</ca>"
    echo "<cert>"; sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$PKI/issued/$name.crt"; echo "</cert>"
    echo "<key>"; cat "$PKI/private/$name.key"; echo "</key>"
    echo "<tls-crypt>"; cat /etc/openvpn/tls-crypt.key; echo "</tls-crypt>"
  } > "$CLIENT_DIR/$name.ovpn"
  chmod 0600 "$CLIENT_DIR/$name.ovpn"
}
client_add(){
  require_root
  name=$1; valid_client "$name" || die "Invalid client name"
  grep -Eq "/CN=$name$" "$PKI/index.txt" 2>/dev/null && die "Client already exists"
  EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" "$EASYRSA" build-client-full "$name" nopass >/dev/null
  profile_build "$name"
  jq -n --arg name "$name" '{ok:true,name:$name}'
}
client_revoke(){
  require_root
  name=$1; valid_client "$name" || die "Invalid client name"
  EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" "$EASYRSA" revoke "$name" >/dev/null
  EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" "$EASYRSA" gen-crl >/dev/null
  chmod 0644 "$PKI/crl.pem"
  rm -f "$CLIENT_DIR/$name.ovpn"
  running && rc-service openvpn.litefwm restart >/dev/null || true
}
client_profile(){
  name=$1; valid_client "$name" || die "Invalid client name"
  [ -r "$CLIENT_DIR/$name.ovpn" ] || die "Client profile not found"
  cat "$CLIENT_DIR/$name.ovpn"
}
snapshot(){
  run=false; running && run=true
  if [ ! -r "$CONF" ]; then
    jq -n --argjson running "$run" --argjson clients "$(clients_json)" '{running:$running,configured:false,clients:$clients}'
    return
  fi
  jq -n --argjson running "$run" \
    --arg publicHost "$(setting public-host)" --arg inboundInterface "$(setting inbound-interface)" \
    --arg interface "$(setting device)" --arg protocol "$(setting protocol)" --arg port "$(setting port)" \
    --arg network "$(setting network)" --arg dns "$(setting dns)" --arg routes "$(setting routes)" \
    --argjson redirectGateway "$(setting redirect-gateway)" --argjson clientToClient "$(setting client-to-client)" \
    --argjson clients "$(clients_json)" \
    '{running:$running,configured:true,publicHost:$publicHost,inboundInterface:$inboundInterface,interface:$interface,protocol:$protocol,port:($port|tonumber),network:$network,dns:($dns|split(",")|map(select(length>0))),routes:($routes|split(",")|map(select(length>0))),redirectGateway:$redirectGateway,clientToClient:$clientToClient,clients:$clients}'
}
firewall(){
  [ -r "$CONF" ] || return 0
  running || return 0
  port=$(setting port); proto=$(setting protocol); inbound=$(setting inbound-interface)
  valid_port "$port" || return 0
  [ "$inbound" = wan ] && inbound=$(ip -4 -j route show default 2>/dev/null | jq -r '.[0].dev // empty')
  [ -n "$inbound" ] || return 0
  p=udp; [ "$proto" = tcp ] && p=tcp
  printf '%s\n' "-A LFW_MOD -i $inbound -p $p -m $p --dport $port -m comment --comment lfw:module:openvpn -j ACCEPT"
}
install_module(){
  require_root
  apk add --no-cache openvpn openvpn-openrc easy-rsa >/dev/null
  modprobe tun
  touch /etc/modules
  grep -qxF tun /etc/modules || echo tun >> /etc/modules
  [ -c /dev/net/tun ] || die "TUN device is unavailable"
  mkdir -p /etc/openvpn "$CLIENT_DIR"
  if [ ! -r "$PKI/ca.crt" ]; then
    EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" "$EASYRSA" init-pki >/dev/null
    EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" EASYRSA_REQ_CN=LiteFWM-CA "$EASYRSA" build-ca nopass >/dev/null
    EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" "$EASYRSA" build-server-full server nopass >/dev/null
    EASYRSA_BATCH=1 EASYRSA_PKI="$PKI" "$EASYRSA" gen-crl >/dev/null
  fi
  [ -r /etc/openvpn/tls-crypt.key ] || openvpn --genkey secret /etc/openvpn/tls-crypt.key
  chmod 0600 /etc/openvpn/tls-crypt.key "$PKI/private/server.key"
  chmod 0644 "$PKI/crl.pem"
  ln -sf openvpn /etc/init.d/openvpn.litefwm
}
uninstall_module(){
  require_root
  rc-service openvpn.litefwm stop >/dev/null 2>&1 || true
  rc-update del openvpn.litefwm default >/dev/null 2>&1 || true
  rm -f /etc/init.d/openvpn.litefwm
  apk del openvpn-openrc openvpn easy-rsa >/dev/null 2>&1 || true
  if [ -r /etc/modules ]; then
    grep -vxF tun /etc/modules > /etc/modules.litefwm.tmp || true
    mv /etc/modules.litefwm.tmp /etc/modules
  fi
  rm -rf /etc/openvpn
}
case "${1:-}" in
  meta) meta;;
  installed) installed;;
  install) install_module;;
  uninstall) uninstall_module;;
  snapshot) snapshot;;
  firewall) firewall;;
  server-set) shift; server_set "$@";;
  client-add) client_add "${2:?NAME}";;
  client-revoke) client_revoke "${2:?NAME}";;
  client-profile) client_profile "${2:?NAME}";;
  service)
    case "${2:-}" in
      start) [ -r "$CONF" ] || die "Configure OpenVPN first"; restart_vpn;;
      stop) rc-service openvpn.litefwm stop; rc-update del openvpn.litefwm default >/dev/null 2>&1 || true;;
      restart) restart_vpn;;
      *) die "service requires start, stop, or restart";;
    esac
    ;;
  *) echo "Unknown OpenVPN module action" >&2; exit 2;;
esac
