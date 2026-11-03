#!/bin/sh
# Independent native OpenVPN client instances. Existing server is untouched.
set -eu
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMMON="$SELF/../../lib/common.sh"
[ -r "$COMMON" ] || COMMON="$SELF/../../common.sh"
[ -r "$COMMON" ] || COMMON=/usr/lib/litefwm/common.sh
. "$COMMON"
COMPAT="$SELF/../../lib/module-compat.sh"
[ -r "$COMPAT" ] || COMPAT="$SELF/../../module-compat.sh"
. "$COMPAT"
DIR=${LFW_OVPN_DIR:-/etc/openvpn}
valid_name(){ printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,30}$'; }
path_for(){ valid_name "$1" || die 'Invalid client tunnel name'; printf '%s/lfwc-%s.conf' "$DIR" "$1"; }
field(){ sed -n "s/^# litefwm:$1=//p" "$2" 2>/dev/null | head -1; }
service_name(){ printf 'openvpn.lfwc-%s' "$1"; }
list(){
  for f in "$DIR"/lfwc-*.conf; do
    [ -r "$f" ] || continue
    n=${f##*/}; n=${n#lfwc-}; n=${n%.conf}
    valid_name "$n" || continue
    service=$(service_name "$n")
    run=false; rc-service "$service" status >/dev/null 2>&1 && run=true
    jq -n --arg id "$n" --arg mode "$(field mode "$f")" \
      --arg remoteHost "$(field remoteHost "$f")" --arg protocol "$(field protocol "$f")" \
      --arg interface "$(field interface "$f")" \
      --arg localSubnet "$(field localSubnet "$f")" \
      --arg remoteSubnet "$(field remoteSubnet "$f")" --argjson running "$run" \
      '{id:$id,mode:$mode,remoteHost:$remoteHost,protocol:$protocol,
       interface:$interface,localSubnet:$localSubnet,remoteSubnet:$remoteSubnet,
       running:$running,credentialsStored:true}'
  done | jq -s .
}
validate_profile(){
  # Full client profile with inline PEM certificate/key sections; deliberately
  # disallow OpenVPN script hooks, plugins, arbitrary file paths, management,
  # gateway redirection, and command-line substitutions.
  awk '
    BEGIN { open=""; count=0; ca=0; cert=0; key=0; tls=0; remote=0; failed=0 }
    {
      line=$0; sub(/\r$/, "", line)
      if (open!="") {
        if (line=="</"open">") { open=""; next }
        if (line ~ /^<[^>]*>$/) {failed=1; exit}
        next
      }
      if (line ~ /^<(ca|cert|key|tls-crypt|tls-auth)>$/) {
        open=substr(line,2,length(line)-2)
        if(open=="ca")ca++
        if(open=="cert")cert++
        if(open=="key")key++
        if(open=="tls-crypt" || open=="tls-auth")tls++
        next
      }
      if(line ~ /^[ \t]*($|#|;)/)next
      if(line ~ /^<[^>]*>/) {failed=1; exit}
      split(line,a,/[ \t]+/); cmd=a[1]
      allowed=" client dev dev-type proto remote resolv-retry nobind persist-key persist-tun remote-cert-tls auth-nocache tls-version-min data-ciphers data-ciphers-fallback auth verb tls-client key-direction verify-x509-name ping ping-restart explicit-exit-notify mute-replay-warnings "
      if(index(allowed, " "cmd" ")==0){failed=1;exit}
      if(cmd=="remote") {
        if (a[2] !~ /^[A-Za-z0-9][A-Za-z0-9.-]*$/ || a[3] !~ /^[0-9]+$/ ||
            a[3]+0<1 || a[3]+0>65535) {failed=1;exit};remote++
      }
      if (cmd=="dev" && a[2] !~ /^tun[0-9]*$/) {failed=1;exit}
    }
    END { if(failed || open!="" || ca!=1 || cert!=1 || key!=1 || tls<1 || remote!=1)exit 1 }
  ' "$1" || die 'Client profile must contain one remote, inline CA/cert/key/tls-crypt, and safe options; scripts, plugins and redirect-gateway are not allowed'
}
save(){
  require_root
  [ "$#" -eq 1 ] && [ -r "$1" ] || die 'Missing OpenVPN client request'
  req=$1
  name=$(jq -r '.id // ""' "$req"); valid_name "$name" || die 'Invalid OpenVPN client name'
  mode=$(jq -r '.mode // ""' "$req")
  case "$mode" in point-to-site|site-to-site) :;; *) die 'Invalid VPN client mode';; esac
  iface=$(jq -r '.interface // ""' "$req")
  printf '%s' "$iface" | grep -Eq '^tun[0-9]{1,2}$' || die 'Client interface must be tunN'
  localSubnet=$(jq -r '.localSubnet // ""' "$req")
  remoteSubnet=$(jq -r '.remoteSubnet // ""' "$req")
  if [ "$mode" = site-to-site ]; then
    valid_cidr "$localSubnet" && valid_cidr "$remoteSubnet" || die 'Site-to-site local and remote networks required'
    [ "$localSubnet" != "$remoteSubnet" ] || die 'Site networks cannot be identical'
  elif [ -n "$remoteSubnet" ]; then valid_cidr "$remoteSubnet" || die 'Invalid remote network'; fi
  f=$(path_for "$name")
  mkdir -p -m 0700 "$DIR"
  tmp=$(mktemp -d "$DIR/.litefw-ovpn.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  jq -r '.profile // ""' "$req" >"$tmp/import.ovpn"
  [ "$(wc -c <"$tmp/import.ovpn")" -le 65536 ] || die 'OpenVPN profile exceeds 64 KiB'
  # Editing other settings without importing a new profile retains existing
  # encrypted material. Never return any profile text in a state snapshot.
  if [ "$(wc -c <"$tmp/import.ovpn")" -le 1 ] && [ -r "$f" ]; then
    sed '/^# litefwm:/d; /^pull-filter ignore "redirect-gateway"$/d; /^route-nopull$/d; /^route [0-9]/d; /^dev tun[0-9]/d' "$f" >"$tmp/import.ovpn"
  fi
  validate_profile "$tmp/import.ovpn"
  host=$(awk '$1=="remote"{print $2;exit}' "$tmp/import.ovpn")
  proto=$(awk '$1=="proto"{print $2;exit}' "$tmp/import.ovpn")
  [ -n "$proto" ] || proto=udp
  # Prevent duplicate interfaces across local OpenVPN client profiles.
  for existing in "$DIR"/lfwc-*.conf; do
    [ -r "$existing" ] || continue
    [ "$existing" = "$f" ] && continue
    grep -qFx "# litefwm:interface=$iface" "$existing" && die 'Another client already uses that tunnel interface'
  done
  new="$tmp/client.conf"
  {
    printf '# litefwm:mode=%s\n' "$mode"
    printf '# litefwm:remoteHost=%s\n' "$host"
    printf '# litefwm:protocol=%s\n' "$proto"
    printf '# litefwm:interface=%s\n' "$iface"
    printf '# litefwm:localSubnet=%s\n' "$localSubnet"
    printf '# litefwm:remoteSubnet=%s\n' "$remoteSubnet"
    # Strip only 'dev'; it is controlled by the separate validated UI field.
    sed '/^[[:space:]]*dev[[:space:]]/d' "$tmp/import.ovpn"
    printf '\ndev %s\npull-filter ignore "redirect-gateway"\n' "$iface"
    if [ "$mode" = site-to-site ]; then
      printf 'route-nopull\n'
      net=${remoteSubnet%/*}; prefix=${remoteSubnet#*/}
      # Re-use the server CIDR mask conversion helper.
      mask=$(awk -v n="$prefix" 'BEGIN {for(i=0;i<4;i++){b=n>=8?8:n;n-=b;v=0;for(j=0;j<b;j++)v+=2^(7-j);printf "%s%d",i?".":"",v}}')
      printf 'route %s %s\n' "$net" "$mask"
    elif [ -n "$remoteSubnet" ]; then
      net=${remoteSubnet%/*}; prefix=${remoteSubnet#*/}
      mask=$(awk -v n="$prefix" 'BEGIN {for(i=0;i<4;i++){b=n>=8?8:n;n-=b;v=0;for(j=0;j<b;j++)v+=2^(7-j);printf "%s%d",i?".":"",v}}')
      printf 'route %s %s\n' "$net" "$mask"
    fi
  } >"$new"
  chmod 0600 "$new"
  if [ -r "$f" ]; then cp -p "$f" "$f.backup.$(date -u +%Y%m%dT%H%M%SZ)" || die 'Profile backup failed'; fi
  mv "$new" "$f"
  service=$(service_name "$name")
  ln -sf openvpn "/etc/init.d/$service"
  # Profile changes NEVER automatically start or restart VPNs.
  jq -n --arg id "$name" '{id:$id,saved:true,started:false}'
}
remove(){
  require_root
  name=$1; f=$(path_for "$name"); [ -r "$f" ] || die 'Client tunnel not found'
  service=$(service_name "$name")
  rc-service "$service" stop >/dev/null 2>&1 || :
  rc-update del "$service" default >/dev/null 2>&1 || :
  cp -p "$f" "$f.backup.$(date -u +%Y%m%dT%H%M%SZ)" || die 'Profile backup failed'
  rm -f "$f" "/etc/init.d/$service"
}
service(){
  require_root
  name=$1; action=$2
  f=$(path_for "$name"); [ -r "$f" ] || die 'Unknown OpenVPN client'
  svc=$(service_name "$name")
  case "$action" in
    start) rc-update add "$svc" default >/dev/null 2>&1 || :; rc-service "$svc" start;;
    stop) rc-service "$svc" stop; rc-update del "$svc" default >/dev/null 2>&1 || :;;
    restart) rc-service "$svc" restart;;
    *) die 'Invalid client service action';;
  esac
}
case "${1:-}" in
  list) list;;
  save) save "$2";;
  delete) remove "$2";;
  service) service "$2" "$3";;
  *) die 'Unknown OpenVPN client instance action';;
esac
