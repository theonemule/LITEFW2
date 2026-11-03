#!/bin/sh
# Shared optional-module controller. Root-only mutation through lfwctl API.
set -eu
MOD=${1:?module}; shift
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
COMMON="$SELF/../lib/common.sh"
[ -r "$COMMON" ] || COMMON="$SELF/../common.sh"
. "$COMMON"
COMPAT="$SELF/../lib/module-compat.sh"
[ -r "$COMPAT" ] || COMPAT="$SELF/../module-compat.sh"
. "$COMPAT"
DIR=${LFW_MODULE_CONFIG_DIR:-/etc/litefw-addons}
CONF="$DIR/$MOD.json"
modinfo(){
 case "$MOD" in
 suricata) NAME="Suricata IDS/IPS"; DESC="Network intrusion detection and optional inline inspection"; CAT=security; PKGS="suricata suricata-openrc python3"; BIN=suricata; SERVICE=litefw-suricata;;
 geoip) NAME="GeoIP Blocking"; DESC="Country IPv4 network blocklists backed by ipset"; CAT=security; PKGS="ipset curl"; BIN=ipset; SERVICE=litefw-geoip;;
 crowdsec) NAME="CrowdSec"; DESC="CrowdSec threat detection with local IPv4 decision-to-ipset remediation"; CAT=security; PKGS="curl ca-certificates ipset"; BIN=cscli; SERVICE=crowdsec;;
 wireguard) NAME="WireGuard"; DESC="Managed wg-quick tunnels with key/peer configuration"; CAT=vpn; PKGS="wireguard-tools python3"; BIN=wg; SERVICE=litefw-wireguard;;
 cloudflared) NAME="Cloudflare Tunnel"; DESC="Token-managed outbound Cloudflare tunnel"; CAT=connectivity; PKGS="curl ca-certificates"; BIN=cloudflared; SERVICE=litefw-cloudflared;;
 multiwan) NAME="Multi-WAN Failover"; DESC="Priority-based multi-uplink default route and gateway health checks"; CAT=network; PKGS="iproute2"; BIN=ip; SERVICE=litefw-multiwan;;
 mdns) NAME="mDNS Repeater"; DESC="LAN-only Avahi DNS-SD reflector across selected segments"; CAT=network; PKGS="avahi avahi-openrc"; BIN=avahi-daemon; SERVICE=avahi-daemon;;
 captive) NAME="Captive Portal"; DESC="Guest splash portal with openNDS"; CAT=network; PKGS="curl ca-certificates libmicrohttpd bash iptables iproute2"; BIN=opennds; SERVICE=opennds;;
 frr) NAME="BGP / FRRouting"; DESC="BGP sessions with explicit neighbors and advertised prefixes"; CAT=routing; PKGS="frr frr-openrc"; BIN=vtysh; SERVICE=frr;;
 *) die "Unknown optional module";;
 esac
}
modinfo
installed(){
 if [ "$MOD" = multiwan ]; then [ -x /usr/local/sbin/litefw-multiwan-check ]; return; fi
 # lfwctl intentionally restricts PATH; verified vendor binaries live in
 # /usr/local/bin and must be found explicitly without broadening the PATH.
 if [ "$MOD" = cloudflared ] || [ "$MOD" = crowdsec ] || [ "$MOD" = captive ]; then
   [ -x "/usr/local/bin/$BIN" ] || return 1
 else
   command -v "$BIN" >/dev/null 2>&1 || return 1
 fi
 case "$MOD" in suricata|wireguard) command -v python3 >/dev/null 2>&1 || return 1;; esac
 if [ -n "$SERVICE" ]; then
   [ -e "/etc/init.d/$SERVICE" ] || return 1
 fi
}
running(){
 case "$MOD" in
 wireguard) [ -r "$CONF" ] || return 1; iface=$(jq -r '.interface // "wg0"' "$CONF"); wg show "$iface" >/dev/null 2>&1;;
 geoip) [ -r "$CONF" ] && [ "$(jq -r '.enabled // false' "$CONF")" = true ] && ipset list litefw_geo4 >/dev/null 2>&1;;
 multiwan) [ -r "$CONF" ] && [ "$(jq -r '.enabled // false' "$CONF")" = true ];;
 *) [ -n "$SERVICE" ] && rc-service "$SERVICE" status >/dev/null 2>&1;;
 esac
}
meta(){ jq -n --arg id "$MOD" --arg name "$NAME" --arg description "$DESC" --arg category "$CAT" '{id:$id,name:$name,description:$description,category:$category}'; }
config_json(){ if [ -s "$CONF" ]; then cat "$CONF"; else echo '{}'; fi; }
snapshot(){
 run=false; running && run=true
 data=$(config_json)
 # Credentials are never emitted, including WireGuard private keys and Cloudflare tokens.
 safe=$(printf '%s' "$data" | jq 'del(.privateKey,.token,.secret,.psk) + {credentialConfigured:((.privateKey // .token // .secret // .psk // "") != "")}')
 case "$MOD" in
 wireguard)
   safe=$(printf '%s' "$safe" | jq '.peers=((.peers // [])|map(del(.presharedKey)))')
   peer_state=$(python3 "$SELF/shared/wireguard-peers.py" list 2>/dev/null || echo '{"peers":[]}')
   safe=$(printf '%s' "$safe" | jq --argjson peers "$peer_state" '. + {peers:$peers.peers,publicKey:($peers.publicKey//"")}')
   ;;
 geoip) count=$(ipset list litefw_geo4 2>/dev/null | awk '/^Number of entries:/{print $4}'); safe=$(printf '%s' "$safe" | jq --argjson count "${count:-0}" '.+{loadedNetworks:$count}');;
 suricata) rule_state=$(python3 "$SELF/shared/suricata-rules.py" list 2>/dev/null || echo '{"sources":[],"rules":[],"activeRules":0,"totalRules":0}');;
 frr) peers=$(vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null || echo '{}'); safe=$(printf '%s' "$safe" | jq --argjson p "$peers" '.+{sessions:$p}');;
 esac
 if [ "$MOD" = suricata ]; then
   jq -n --argjson running "$run" --argjson settings "$safe" --argjson extra "$rule_state"      '{running:$running,configured:($settings|has("interface")),settings:$settings} + $extra'
 else
   jq -n --argjson running "$run" --argjson settings "$safe" '{running:$running,configured:($settings|has("enabled") or has("interface") or has("interfaces") or has("asn") or .credentialConfigured),settings:$settings}'
 fi
}
# Accept bounded JSON, checked against module-specific validation before mutating native config.
validate(){
 jq -e 'type=="object"' "$1" >/dev/null || die 'Configuration must be an object'
 case "$MOD" in
 suricata)
 jq -e '(.interface|type=="string" and test("^[a-zA-Z0-9_.-]{1,15}$")) and (.mode=="ids" or .mode=="ips")' "$1" >/dev/null || die 'Specify valid interface and ids/ips mode'
 ;;
 geoip)
 jq -e '(.countries|type=="array" and length>0 and length<=100 and all(.[];type=="string" and test("^[a-z]{2}$"))) and ((.enabled//false)|type=="boolean")' "$1" >/dev/null || die 'Choose 1-100 two-letter country codes'
 ;;
 crowdsec) jq -e '((.enabled//false)|type=="boolean")' "$1" >/dev/null || die 'Invalid CrowdSec settings';;
 wireguard)
 jq -e '(.interface|type=="string" and test("^wg[0-9]{1,3}$")) and (.address|type=="string" and test("^[0-9./, ]+$")) and (.listenPort|type=="number" and .>=1 and .<=65535) and ((.peers//[])|type=="array" and length<=32 and all(.[]; (.publicKey|type=="string" and test("^[A-Za-z0-9+/]{43}=$")) and (.allowedIPs|type=="string" and test("^[0-9./:, a-fA-F]+$")) ))' "$1" >/dev/null || die 'Invalid WireGuard interface, address, port or peers'
 ;;
 cloudflared)
 jq -e '(.token|type=="string" and length>=20 and length<=4096)' "$1" >/dev/null || die 'Cloudflare tunnel token required (20-4096 characters)'
 ;;
 multiwan)
 jq -e '(.uplinks|type=="array" and length>=2 and length<=8 and all(.[]; (.interface|type=="string" and test("^[a-zA-Z0-9_.-]{1,15}$")) and (.gateway|type=="string" and test("^[0-9.]+$")) and (.priority|type=="number" and .>=1 and .<=10000))) and ((.enabled//false)|type=="boolean")' "$1" >/dev/null || die 'Configure two or more WAN uplinks'
 ;;
 mdns)
 jq -e '(.interfaces|type=="array" and length>=2 and length<=12 and all(.[];type=="string" and test("^[A-Za-z0-9_.-]{1,15}$")))' "$1" >/dev/null || die 'Select two or more LAN interfaces'
 ;;
 captive)
 jq -e '(.interface|type=="string" and test("^[A-Za-z0-9_.-]{1,15}$")) and (.gatewayName|type=="string" and length>=1 and length<=40 and test("^[A-Za-z0-9 _.-]+$"))' "$1" >/dev/null || die 'Invalid guest interface or gateway name'
 ;;
 frr)
 jq -e '(.asn|type=="number" and .>=1 and .<=4294967294) and (.routerId|type=="string" and test("^[0-9.]+$")) and (.neighbors|type=="array" and length>=1 and length<=32 and all(.[]; (.address|type=="string" and test("^[0-9.]+$")) and (.remoteAs|type=="number" and .>=1 and .<=4294967294))) and ((.networks//[])|type=="array" and length<=32 and all(.[];type=="string" and test("^[0-9./]+$")))' "$1" >/dev/null || die 'Invalid BGP ASN/router ID/neighbors/networks'
 ;;
 esac
}
# Create native service configuration only after validation; replace atomically.
render(){
 case "$MOD" in
 suricata)
   iface=$(jq -r '.interface' "$1"); mode=$(jq -r '.mode' "$1")
   [ -e "/sys/class/net/$iface" ] || die 'Interface not present'
   # Use local OpenRC service; nothing is enabled on installation.
   cat > /etc/conf.d/litefw-suricata <<EOF
SURICATA_IFACE="$iface"
SURICATA_MODE="$mode"
EOF
   ;;
 wireguard)
   iface=$(jq -r '.interface' "$1"); address=$(jq -r '.address' "$1"); port=$(jq -r '.listenPort' "$1")
   priv=$(jq -r '.privateKey // empty' "$1")
   [ -n "$priv" ] || priv=$(sed -n 's/^PrivateKey = //p' "/etc/wireguard/$iface.conf" 2>/dev/null | head -1)
   printf '%s' "$priv" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || die 'WireGuard private key required'
   for cidr in $(printf '%s' "$address" | tr ',' ' '); do
     is_cidr "$cidr" || die 'WireGuard address must be IPv4 CIDR'
   done
   jq -r '.peers[]? | .allowedIPs' "$1" | tr ',' '\n' | while IFS= read -r cidr; do
     cidr=$(printf '%s' "$cidr" | tr -d ' ')
     is_cidr "$cidr" || die 'Invalid WireGuard AllowedIPs IPv4 CIDR'
   done
   jq -e 'all(.peers[]?; ((.endpoint//"")|test("^[A-Za-z0-9.:-]{0,253}$")) and ((.persistentKeepalive//0)|type=="number" and .>=0 and .<=65535))' "$1" >/dev/null || die 'Invalid peer endpoint/keepalive'
   mkdir -p /etc/wireguard
   if [ -s "/etc/wireguard/$iface.conf" ]; then
     grep -q '^# managed by LiteFW' "/etc/wireguard/$iface.conf" || die 'Refusing overwrite of unmanaged WireGuard config'
   fi
   tmp=$(mktemp)
   { printf '# managed by LiteFW\n[Interface]\nAddress = %s\nListenPort = %s\nPrivateKey = %s\n' "$address" "$port" "$priv"
     jq -r '.peers[]? | select(.enabled != false) | "\n[Peer]\nPublicKey = \(.publicKey)\nAllowedIPs = \(.allowedIPs)\n" + (if (.endpoint//"")!="" then "Endpoint = \(.endpoint)\n" else "" end) + (if (.persistentKeepalive//0)>0 then "PersistentKeepalive = \(.persistentKeepalive)\n" else "" end)' "$1"
   } >"$tmp"
   install -m 0600 "$tmp" "/etc/wireguard/$iface.conf"; rm -f "$tmp"
   ;;
 cloudflared)
   token=$(jq -r '.token' "$1")
   mkdir -p /etc/cloudflared
   printf '%s\n' "$token" | install -m 0600 /dev/stdin /etc/cloudflared/litefw-token
   ;;
 mdns)
   interfaces=$(jq -r '.interfaces|join(",")' "$1")
   for iface in $(printf '%s' "$interfaces" | tr ',' ' '); do
     [ -e "/sys/class/net/$iface" ] || die "Interface missing: $iface"
     [ "$iface" != "$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}')" ] || die 'Refusing mDNS reflector on WAN'
   done
   mkdir -p /etc/avahi
   if [ -s /etc/avahi/avahi-daemon.conf ] && ! grep -q '^# managed by LiteFW' /etc/avahi/avahi-daemon.conf; then
     [ -r /etc/avahi/avahi-daemon.conf.litefw.backup ] ||
       cp -p /etc/avahi/avahi-daemon.conf /etc/avahi/avahi-daemon.conf.litefw.backup
   fi
   cat >/etc/avahi/avahi-daemon.conf <<EOF
# managed by LiteFW
[server]
use-ipv4=yes
use-ipv6=no
allow-interfaces=$interfaces
[wide-area]
enable-wide-area=no
[publish]
disable-publishing=yes
[reflector]
enable-reflector=yes
reflect-ipv=no
EOF
   ;;
 captive)
   iface=$(jq -r '.interface' "$1")
   [ -e "/sys/class/net/$iface" ] || die 'Guest interface missing'
   [ "$iface" != "$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}')" ] || die 'Captive portal must never use WAN'
   mkdir -p /etc/opennds
   cat >/etc/opennds/opennds.conf <<EOF
GatewayInterface $iface
GatewayName $(jq -r '.gatewayName' "$1")
GatewayPort 2050
EOF
   ;;
 frr)
   router=$(jq -r '.routerId' "$1"); is_ipv4 "$router" || die 'Invalid BGP router ID'
   jq -r '.neighbors[].address' "$1" | while IFS= read -r addr; do is_ipv4 "$addr" || die 'Invalid BGP neighbor IPv4 address'; done
   jq -r '.networks[]?' "$1" | while IFS= read -r prefix; do is_cidr "$prefix" || die 'Invalid BGP advertised prefix'; done
   mkdir -p /etc/frr
   if [ -s /etc/frr/frr.conf ] && ! grep -q '^! managed by LiteFW' /etc/frr/frr.conf; then
     if grep -Eq '^router (bgp|ospf|isis)|^ip route ' /etc/frr/frr.conf; then
       die 'Refusing to overwrite existing routing configuration'
     fi
     [ -s /etc/frr/frr.conf.litefw.backup ] || cp -p /etc/frr/frr.conf /etc/frr/frr.conf.litefw.backup
   fi
   tmp=$(mktemp)
   { echo '! managed by LiteFW'; echo 'frr defaults traditional'; echo 'service integrated-vtysh-config'; echo 'router bgp '$(jq -r '.asn' "$1"); echo " bgp router-id $router"; echo ' bgp enforce-first-as'
     jq -r '.neighbors[] | " neighbor \(.address) remote-as \(.remoteAs)"' "$1"
     echo ' address-family ipv4 unicast'
     jq -r '.networks[]? | "  network \(.)"' "$1"
     jq -r '.neighbors[].address | "  neighbor \(.) route-map LFW-IN in\n  neighbor \(.) route-map LFW-OUT out"' "$1"
     echo ' exit-address-family'
     echo 'route-map LFW-IN deny 10'
     if [ "$(jq -r '.networks|length' "$1")" -gt 0 ]; then
       jq -r '.networks | to_entries[] | "ip prefix-list LFW-EXPORT seq \((.key+1)*10) permit \(.value)"' "$1"
       echo 'route-map LFW-OUT permit 10'
       echo ' match ip address prefix-list LFW-EXPORT'
       echo 'route-map LFW-OUT deny 100'
     else echo 'route-map LFW-OUT deny 10'; fi
   } >"$tmp"
   vtysh -C -f "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die 'FRR rejected proposed BGP configuration'; }
   # Avoid enabling BGP until the operator explicitly starts FRR.
   install -m 0640 "$tmp" /etc/frr/frr.conf; rm -f "$tmp"
   if [ -r /etc/frr/daemons ]; then sed -i 's/^bgpd=no$/bgpd=yes/' /etc/frr/daemons; fi
   ;;
 esac
}
configure(){
 require_root; [ -r "$1" ] || die 'Configuration missing'
 jq -e 'type=="object"' "$1" >/dev/null || die 'Invalid JSON request'
 mkdir -p "$DIR"; chmod 0700 "$DIR"
 # Keep credentials across edits when user submits blank fields.
 if [ -r "$CONF" ]; then
  jq -s '.[0] as $old | .[1] | if (.privateKey//"")=="" then .privateKey=$old.privateKey else . end | if (.token//"")=="" then .token=$old.token else . end' "$CONF" "$1" >"$DIR/$MOD.pending"
 else cp "$1" "$DIR/$MOD.pending"; fi
 chmod 0600 "$DIR/$MOD.pending"
 validate "$DIR/$MOD.pending"
 if [ "$MOD" = wireguard ]; then
   if [ "$(jq -r '.privateKey // ""' "$DIR/$MOD.pending")" = "" ]; then
     iface=$(jq -r '.interface' "$DIR/$MOD.pending")
     key=$(sed -n 's/^PrivateKey = //p' "/etc/wireguard/$iface.conf" 2>/dev/null | head -1)
     [ -n "$key" ] || key=$(wg genkey) || die 'Could not generate server WireGuard key'
     jq --arg key "$key" '.privateKey=$key' "$DIR/$MOD.pending" >"$DIR/$MOD.keytmp"
     chmod 0600 "$DIR/$MOD.keytmp"
     mv "$DIR/$MOD.keytmp" "$DIR/$MOD.pending"
   fi
   jq -e '((.serverEndpoint//"")|type=="string" and test("^[A-Za-z0-9.-]{0,253}$")) and ((.dns//"")|type=="string" and test("^[0-9.]{0,15}$"))' "$DIR/$MOD.pending" >/dev/null || die 'Invalid WireGuard client endpoint or DNS'
 fi
 if [ "$MOD" = multiwan ]; then
   jq -r '.uplinks[].gateway' "$DIR/$MOD.pending" | while IFS= read -r gateway; do
     is_ipv4 "$gateway" || die 'Invalid multi-WAN gateway IPv4 address'
   done
   dup=$(jq -r '.uplinks[].interface' "$DIR/$MOD.pending" | sort | uniq -d)
   [ -z "$dup" ] || die 'Duplicate multi-WAN interface'
 fi
 render "$DIR/$MOD.pending"
 mv "$DIR/$MOD.pending" "$CONF"
 snapshot
}
install_mod(){
 require_root
 [ "$MOD" != multiwan ] || { apk add --no-cache iproute2; mkdir -p /usr/local/sbin; install -m 0755 "$SELF/shared/multiwan-check.sh" /usr/local/sbin/litefw-multiwan-check; return; }
 case "$MOD" in
   cloudflared|crowdsec|captive)
     "$SELF/shared/vendor-install.sh" "$MOD" || die "Verified vendor installer for $MOD failed";;
   *)
     apk add --no-cache $PKGS || die "Alpine packages unavailable: $PKGS";;
 esac
 case "$MOD" in
 suricata|cloudflared|geoip|wireguard|captive) install -m 0755 "$SELF/shared/init-$MOD" "/etc/init.d/$SERVICE";;
 crowdsec)
   install -m 0755 "$SELF/shared/init-crowdsec" /etc/init.d/crowdsec;
   mkdir -p /usr/local/sbin
   install -m 0755 "$SELF/shared/init-crowdsec-bouncer" /etc/init.d/litefw-crowdsec-bouncer
   install -m 0755 "$SELF/shared/crowdsec-sync.sh" /usr/local/sbin/litefw-crowdsec-sync;;
 esac
 installed || die "Native executable or OpenRC service missing after installation: $MOD"
}
remove_mod(){
 require_root
 if [ -n "$SERVICE" ]; then rc-service "$SERVICE" stop >/dev/null 2>&1 || true; rc-update del "$SERVICE" default >/dev/null 2>&1 || true; fi
 case "$MOD" in
 wireguard)
   if [ -r "$CONF" ]; then
     wgif=$(jq -r '.interface // ""' "$CONF")
     [ -z "$wgif" ] || /bin/bash /usr/bin/wg-quick down "$wgif" >/dev/null 2>&1 || true
     if [ -n "$wgif" ] && [ -r "/etc/wireguard/$wgif.conf" ] &&
       grep -q '^# managed by LiteFW' "/etc/wireguard/$wgif.conf"; then
       rm -f "/etc/wireguard/$wgif.conf"
     fi
   fi;;
 geoip) ipset destroy litefw_geo4 >/dev/null 2>&1 || true; rm -f /etc/init.d/litefw-geoip;;
 crowdsec)
   rc-update del litefw-crowdsec-bouncer boot >/dev/null 2>&1 || true
   if [ -r /etc/crontabs/root ]; then
     sed '/# litefw-crowdsec$/d' /etc/crontabs/root >/etc/crontabs/root.lfw.tmp &&
       mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
   fi
   ipset destroy litefw_cs4 >/dev/null 2>&1 || true
   rm -f /etc/init.d/litefw-crowdsec-bouncer /usr/local/sbin/litefw-crowdsec-sync /etc/init.d/crowdsec /usr/local/bin/crowdsec /usr/local/bin/cscli;;
 cloudflared) rm -f /etc/init.d/litefw-cloudflared /usr/local/bin/cloudflared /etc/cloudflared/litefw-token;;
 suricata) rm -f /etc/init.d/litefw-suricata /etc/conf.d/litefw-suricata;;
 multiwan)
   if [ -r /etc/crontabs/root ]; then
     sed '/# litefw-multiwan$/d' /etc/crontabs/root >/etc/crontabs/root.lfw.tmp &&
       mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
   fi
   if [ -s /run/litefwm/multiwan-original-route ]; then
     ip -4 route replace $(cat /run/litefwm/multiwan-original-route) ||
       die 'Cannot remove multi-WAN until prior route is restored'
     rm -f /run/litefwm/multiwan-original-route
   fi
   rm -f /usr/local/sbin/litefw-multiwan-check;;
 mdns)
   if [ -r /etc/avahi/avahi-daemon.conf.litefw.backup ]; then
     mv /etc/avahi/avahi-daemon.conf.litefw.backup /etc/avahi/avahi-daemon.conf
   fi;;
 captive) rm -f /etc/init.d/opennds /usr/local/bin/opennds /usr/local/bin/ndsctl;;
 frr)
   if [ -r /etc/frr/frr.conf.litefw.backup ]; then
     mv /etc/frr/frr.conf.litefw.backup /etc/frr/frr.conf
   fi;;
 esac
 rm -f "$CONF"
 # Shared OS tools must never be uninstalled by removing one module.
 # Otherwise DNS updates or another firewall module could lose curl/ipset.
 case "$MOD" in
   multiwan|geoip|cloudflared|crowdsec|captive) :;;
   suricata) apk del suricata suricata-openrc >/dev/null 2>&1 || true;;
   wireguard) apk del wireguard-tools >/dev/null 2>&1 || true;;
   *) apk del $PKGS >/dev/null 2>&1 || true;;
 esac
}
service_action(){
 action=$1; case "$action" in start|stop|restart) :;; *) die 'Invalid service action';; esac
 [ -r "$CONF" ] || die 'Configure module first'
 case "$MOD" in
 frr)
   if [ "$action" != stop ]; then jq -e '.neighbors|length>=1' "$CONF" >/dev/null || die 'Add at least one BGP neighbor before starting'; fi
   if [ "$action" = stop ]; then rc-service frr stop; rc-update del frr default >/dev/null 2>&1 || true
   else rc-update add frr default >/dev/null 2>&1 || true; rc-service frr "$action"; fi;;
 wireguard)
   if [ "$action" = stop ]; then
     rc-service litefw-wireguard stop
     rc-update del litefw-wireguard default >/dev/null 2>&1 || true
   else
     rc-update add litefw-wireguard default >/dev/null 2>&1 || true
     rc-service litefw-wireguard "$action" || die 'Unable to activate WireGuard interface'
   fi;;
 crowdsec)
   if [ "$action" = stop ]; then
     rc-service crowdsec stop || die 'CrowdSec stop failed'
     rc-update del crowdsec default >/dev/null 2>&1 || true
     rc-update del litefw-crowdsec-bouncer boot >/dev/null 2>&1 || true
     jq '.enabled=false' "$CONF" >"$CONF.tmp"
     if [ -r /etc/crontabs/root ]; then
       sed '/# litefw-crowdsec$/d' /etc/crontabs/root >/etc/crontabs/root.lfw.tmp &&
         mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
     fi
   else
     rc-update add crowdsec default >/dev/null 2>&1 || true
     rc-service crowdsec "$action" || die 'CrowdSec security engine failed to start'
     rc-service litefw-crowdsec-bouncer start || die 'CrowdSec IP set failed to initialize'
     rc-update add litefw-crowdsec-bouncer boot >/dev/null 2>&1 || true
     jq '.enabled=true' "$CONF" >"$CONF.tmp"; chmod 0600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
     mkdir -p /etc/crontabs
     if [ -r /etc/crontabs/root ]; then
       sed '/# litefw-crowdsec$/d' /etc/crontabs/root >/etc/crontabs/root.lfw.tmp
     else : >/etc/crontabs/root.lfw.tmp; fi
     printf '* * * * * /usr/local/sbin/litefw-crowdsec-sync >/dev/null 2>&1 # litefw-crowdsec\n' >>/etc/crontabs/root.lfw.tmp
     mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
     rc-service crond restart >/dev/null 2>&1 || true
     /usr/local/sbin/litefw-crowdsec-sync || die 'CrowdSec initial decision sync failed'
   fi
   if [ -f "$CONF.tmp" ]; then chmod 0600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF"; fi;;
 geoip)
   if [ "$action" = stop ]; then
     jq '.enabled=false' "$CONF" >"$CONF.tmp"
     rc-update del litefw-geoip boot >/dev/null 2>&1 || true
   else
     [ -s "$DIR/geoip.ipset" ] || die 'Refresh country feeds before enabling GeoIP blocking'
     rc-service litefw-geoip start || die 'Failed to restore GeoIP IP set'
     rc-update add litefw-geoip boot >/dev/null 2>&1 || true
     jq '.enabled=true' "$CONF" >"$CONF.tmp"
   fi
   chmod 0600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF";;
 multiwan)
   if [ "$action" = stop ]; then
     jq '.enabled=false' "$CONF" >"$CONF.tmp"; chmod 0600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
     if [ -s /run/litefwm/multiwan-original-route ]; then
       ip -4 route replace $(cat /run/litefwm/multiwan-original-route) ||
         die 'Could not restore the previous default route'
       rm -f /run/litefwm/multiwan-original-route
     fi
     if [ -r /etc/crontabs/root ]; then
       sed '/# litefw-multiwan$/d' /etc/crontabs/root >/etc/crontabs/root.lfw.tmp &&
         mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
     fi
   else
     jq '.enabled=true' "$CONF" >"$CONF.tmp"; chmod 0600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
     if ! /usr/local/sbin/litefw-multiwan-check; then
       jq '.enabled=false' "$CONF" >"$CONF.tmp"; chmod 0600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
       die 'No healthy uplink, original route preserved'
     fi
     mkdir -p /etc/crontabs
     if [ -f /etc/crontabs/root ]; then sed '/# litefw-multiwan$/d' /etc/crontabs/root > /etc/crontabs/root.lfw.tmp
     else : > /etc/crontabs/root.lfw.tmp; fi
     printf '* * * * * /usr/local/sbin/litefw-multiwan-check >/dev/null 2>&1 # litefw-multiwan\n' >>/etc/crontabs/root.lfw.tmp
     mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
     rc-service crond restart >/dev/null 2>&1 || true
   fi;;
 *)
   if [ "$action" = stop ]; then rc-service "$SERVICE" stop; rc-update del "$SERVICE" default >/dev/null 2>&1 || true
   else rc-update add "$SERVICE" default >/dev/null 2>&1 || true; rc-service "$SERVICE" "$action"; fi;;
 esac
 snapshot
}
firewall(){
 running || return 0
 case "$MOD" in
 crowdsec)
   [ "$(jq -r '.enabled // false' "$CONF")" = true ] || return 0
   ipset list litefw_cs4 >/dev/null 2>&1 || return 0
   echo '-A LFW_MOD -m set --match-set litefw_cs4 src -m comment --comment lfw:module:crowdsec -j DROP'
   echo '-A LFW_FWD -m set --match-set litefw_cs4 src -m comment --comment lfw:module:crowdsec -j DROP';;
 geoip) echo '-A LFW_MOD -m set --match-set litefw_geo4 src -m comment --comment lfw:module:geoip -j DROP'
        echo '-A LFW_FWD -m set --match-set litefw_geo4 src -m comment --comment lfw:module:geoip -j DROP';;
 wireguard)
  port=$(jq -r '.listenPort' "$CONF"); echo "-A LFW_MOD -p udp --dport $port -m comment --comment lfw:module:wireguard -j ACCEPT";;
 suricata) if [ "$(jq -r '.mode' "$CONF")" = ips ]; then echo '-A LFW_FWD -j NFQUEUE --queue-num 0 --queue-bypass'; fi;;
 captive) echo '-A LFW_MOD -p tcp --dport 2050 -m comment --comment lfw:module:captive -j ACCEPT';;
 frr) jq -r '.neighbors[].address' "$CONF" | while read -r peer; do echo "-A LFW_MOD -s $peer -p tcp --dport 179 -m comment --comment lfw:module:frr -j ACCEPT"; done;;
 mdns) jq -r '.interfaces[]' "$CONF" | while read -r iface; do echo "-A LFW_MOD -i $iface -d 224.0.0.251 -p udp --dport 5353 -m comment --comment lfw:module:mdns -j ACCEPT"; done;;
 esac
}
refresh_geoip(){
 [ "$MOD" = geoip ] || die 'Refresh supported only for GeoIP'
 [ -r "$CONF" ] || die 'Configure countries first'
 command -v curl >/dev/null 2>&1 || die 'curl unavailable'
 tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
 : >"$tmp/blocks"
 for c in $(jq -r '.countries[]' "$CONF"); do
  curl -fsSL --connect-timeout 8 --max-time 25 "https://www.ipdeny.com/ipblocks/data/aggregated/$c-aggregated.zone" >>"$tmp/blocks" || die "Could not download verified HTTPS GeoIP feed for $c"
 done
 awk '/^[0-9.]+\/[0-9]+$/{print $0}' "$tmp/blocks" | sort -u >"$tmp/clean"
 lines=$(wc -l <"$tmp/clean"); [ "$lines" -ge 10 ] && [ "$lines" -le 250000 ] || die 'GeoIP feed invalid or empty'
 while read -r prefix; do is_cidr "$prefix" || die "Invalid GeoIP CIDR $prefix"; done <"$tmp/clean"
 ipset create litefw_geo4 hash:net family inet maxelem 300000 -exist
 ipset create litefw_geo_tmp hash:net family inet maxelem 300000 -exist
 ipset flush litefw_geo_tmp
 sed 's/^/add litefw_geo_tmp /' "$tmp/clean" | ipset restore || die 'IP set import failed'
 ipset swap litefw_geo_tmp litefw_geo4
 ipset destroy litefw_geo_tmp
 ipset save litefw_geo4 >"$DIR/geoip.ipset"
 jq -n --argjson count "$lines" '{loadedNetworks:$count}'
}
case "${1:-}" in
 meta) meta;;
 installed) installed;;
 snapshot) snapshot;;
 firewall) firewall;;
 install) install_mod;;
 uninstall) remove_mod;;
 configure) configure "${2:?JSON-file}";;
 service) service_action "${2:-}";;
 refresh) refresh_geoip;;
 decisions-sync)
   [ "$MOD" = crowdsec ] || die 'Unsupported decision action'
   /usr/local/sbin/litefw-crowdsec-sync;;
 peerset|peerenable|peerremove|clientprofile)
   [ "$MOD" = wireguard ] || die 'Unsupported action'
   python3 "$SELF/shared/wireguard-peers.py" "$1" "${2:?JSON body}";;
  sourceset|sourceenable|sourceremove|sourcerefresh|rulesupload|ruleenable|rulesexport|rulesupdate)
   [ "$MOD" = suricata ] || die 'Unsupported action'
   python3 "$SELF/shared/suricata-rules.py" "$1" "${2:?JSON body}";;
 rules-update)
   [ "$MOD" = suricata ] || die 'Unsupported action'
   python3 "$SELF/shared/suricata-rules.py" rulesupdate "${2:?JSON body}";;
 validate) validate "${2:?JSON-file}";;
 *) die "Unknown $MOD action: ${1:-}";;
esac
