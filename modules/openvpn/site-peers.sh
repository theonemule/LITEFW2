#!/bin/sh
# Site-to-site peer definitions layered onto the existing LiteFW OpenVPN server.
set -eu
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMMON="$SELF/../../lib/common.sh"
[ -r "$COMMON" ] || COMMON="$SELF/../../common.sh"
[ -r "$COMMON" ] || COMMON=/usr/lib/litefwm/common.sh
. "$COMMON"
COMPAT="$SELF/../../lib/module-compat.sh"
[ -r "$COMPAT" ] || COMPAT="$SELF/../../module-compat.sh"
. "$COMPAT"
DIR=${LFW_OVPN_SITE_DIR:-/etc/openvpn/ccd}
CONF=${LFW_OVPN_SERVER_CONF:-/etc/openvpn/litefwm.conf}
valid_name(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'; }
mask_of(){
  printf '%s' "$1" | awk -F/ '
  NF==2 && $2>=8 && $2<=30 {
    n=$2;for(i=0;i<4;i++){b=n>=8?8:n;n-=b;v=0;for(j=0;j<b;j++)v+=2^(7-j);
    printf "%s%d",i?".":"",v}
  }'
}
field(){ sed -n "s/^# litefwm:$1=//p" "$2" 2>/dev/null | head -1; }
list(){
  for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.backup.*|*/.site.*) continue;; esac
    n=${f##*/}
    valid_name "$n" || continue
    [ -n "$(field remoteSubnet "$f")" ] || continue
    jq -n --arg id "$n" --arg localSubnet "$(field localSubnet "$f")" \
      --arg remoteSubnet "$(field remoteSubnet "$f")" \
      '{id:$id,localSubnet:$localSubnet,remoteSubnet:$remoteSubnet,mode:"site-to-site"}'
  done | jq -s .
}
routes_refresh(){
  [ -r "$CONF" ] || return 0
  mkdir -p "$DIR"
  routefile=$(mktemp)
  {
    for f in "$DIR"/*; do
      [ -r "$f" ] || continue
      case "$f" in *.backup.*|*/.site.*) continue;; esac
      net=$(field remoteSubnet "$f")
      [ -n "$net" ] || continue
      printf 'route %s %s\n' "${net%/*}" "$(mask_of "$net")"
    done
  } >"$routefile"
  # Only LiteFW-created lines and include directive are modified.
  tmp=$(mktemp)
  sed '/^client-config-dir \/etc\/openvpn\/ccd$/d; /^# litefwm:site-route-start$/,/^# litefwm:site-route-end$/d' "$CONF" >"$tmp"
  {
    cat "$tmp"
    echo 'client-config-dir /etc/openvpn/ccd'
    echo '# litefwm:site-route-start'
    cat "$routefile"
    echo '# litefwm:site-route-end'
  } >"$CONF.tmp"
  chmod 0600 "$CONF.tmp"
  cp -p "$CONF" "$CONF.backup.$(date -u +%Y%m%dT%H%M%SZ)" || exit 1
  mv "$CONF.tmp" "$CONF"
  rm -f "$tmp" "$routefile"
}
save(){
  require_root
  [ "$#" -eq 1 ] && [ -r "$1" ] || die 'Missing site peer request'
  name=$(jq -r '.id // ""' "$1")
  localSubnet=$(jq -r '.localSubnet // ""' "$1")
  remoteSubnet=$(jq -r '.remoteSubnet // ""' "$1")
  valid_name "$name" || die 'Invalid site peer name'
  valid_cidr "$localSubnet" && valid_cidr "$remoteSubnet" || die 'Both site network CIDRs are required'
  [ "$localSubnet" != "$remoteSubnet" ] || die 'Local and remote subnets must differ'
  [ -r "$CONF" ] || die 'Configure the OpenVPN server before site peers'
  # Only previously issued client certificates can become routing peers.
  [ -r "/etc/openvpn/pki/issued/$name.crt" ] || die 'Issue an OpenVPN client certificate with this name first'
  mkdir -p -m 0700 "$DIR"
  f="$DIR/$name"
  t=$(mktemp "$DIR/.site.XXXXXX")
  {
    printf '# litefwm:localSubnet=%s\n' "$localSubnet"
    printf '# litefwm:remoteSubnet=%s\n' "$remoteSubnet"
    printf 'iroute %s %s\n' "${remoteSubnet%/*}" "$(mask_of "$remoteSubnet")"
    printf 'push "route %s %s"\n' "${localSubnet%/*}" "$(mask_of "$localSubnet")"
  } >"$t"
  chmod 0600 "$t"
  [ ! -f "$f" ] || cp -p "$f" "$f.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$t" "$f"
  routes_refresh
  # No server restart on save: only explicit Restart applies new peer routes.
  jq -n --arg id "$name" '{id:$id,saved:true,restartRequired:true}'
}
delete(){
  require_root
  name=$1; valid_name "$name" || die 'Invalid site peer name'
  f="$DIR/$name"; [ -r "$f" ] || die 'Unknown site peer'
  cp -p "$f" "$f.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  rm -f "$f"
  routes_refresh
}
case "${1:-}" in
  list) list;;
  save) save "$2";;
  delete) delete "$2";;
  routes-refresh) routes_refresh;;
  *) die 'Unknown OpenVPN site peer action';;
esac
