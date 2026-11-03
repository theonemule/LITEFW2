#!/bin/sh
# LiteFW strongSwan IKEv2 site-to-site tunnels, native swanctl snippets.
set -eu
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMMON="$SELF/../../lib/common.sh"
[ -r "$COMMON" ] || COMMON="$SELF/../../common.sh"
[ -r "$COMMON" ] || COMMON=/usr/lib/litefwm/common.sh
. "$COMMON"
COMPAT="$SELF/../../lib/module-compat.sh"
[ -r "$COMPAT" ] || COMPAT="$SELF/../../module-compat.sh"
. "$COMPAT"
DIR=${LFW_IPSEC_DIR:-/etc/swanctl/conf.d}
meta(){ jq -n '{id:"ipsec",name:"IPsec (strongSwan)",description:"Configurable IKEv2 site-to-site tunnels using PSK with per-tunnel connection controls.",category:"vpn"}'; }
installed(){ command -v swanctl >/dev/null 2>&1 && [ -x /etc/init.d/charon ]; }
running(){ rc-service charon status >/dev/null 2>&1; }
valid_name(){ printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,30}$'; }
valid_identity(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._@:-]{1,253}$'; }
valid_peer(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$'; }
valid_key(){ [ "${#1}" -ge 20 ] && [ "${#1}" -le 256 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._~+/=@:-]+$'; }
path_for(){
  valid_name "$1" || die 'Invalid IPsec tunnel name'
  [ -f "$DIR/litefwm-$1.conf" ] && { printf '%s/litefwm-%s.conf' "$DIR" "$1"; return; }
  [ -f "$DIR/litefwm-$1.disabled" ] && { printf '%s/litefwm-%s.disabled' "$DIR" "$1"; return; }
  printf '%s/litefwm-%s.conf' "$DIR" "$1"
}
field(){ sed -n "s/^# litefwm:$1=//p" "$2" 2>/dev/null | head -1; }
all_names(){
  for f in "$DIR"/litefwm-*.conf "$DIR"/litefwm-*.disabled; do
    [ -r "$f" ] || continue
    n=${f##*/}; n=${n#litefwm-}; n=${n%.conf}; n=${n%.disabled}
    valid_name "$n" && printf '%s\n' "$n"
  done
}
snapshot(){
  active=false; running && active=true
  tunnels=$(
    for n in $(all_names); do
      f=$(path_for "$n")
      established=false
      if [ "$active" = true ]; then
        swanctl --list-sas 2>/dev/null | grep -Fq "litefwm-$n:" && established=true
      fi
      jq -n --argjson established "$established" --arg id "$n" --arg peer "$(field peer "$f")" \
        --arg local "$(field localSubnet "$f")" --arg remote "$(field remoteSubnet "$f")" \
        --arg localId "$(field localId "$f")" --arg remoteId "$(field remoteId "$f")" \
        --argjson enabled "$(field enabled "$f")" \
        '{id:$id,mode:"site-to-site",peer:$peer,localSubnet:$local,remoteSubnet:$remote,
          localId:$localId,remoteId:$remoteId,enabled:$enabled,established:$established,credentialConfigured:true}'
    done | jq -s .
  )
  jq -n --argjson running "$active" --argjson tunnels "$tunnels" \
    '{running:$running,configured:($tunnels|length>0),tunnels:$tunnels}'
}
save(){
  require_root
  [ "$#" -eq 1 ] && [ -r "$1" ] || die 'Expected IPsec tunnel request'
  req=$1
  name=$(jq -r '.id // ""' "$req"); valid_name "$name" || die 'Invalid tunnel name'
  f=$(path_for "$name")
  peer=$(jq -r '.peer // ""' "$req")
  localSubnet=$(jq -r '.localSubnet // ""' "$req")
  remoteSubnet=$(jq -r '.remoteSubnet // ""' "$req")
  localId=$(jq -r '.localId // ""' "$req")
  remoteId=$(jq -r '.remoteId // ""' "$req")
  enabled=$(jq -r '.enabled // false' "$req")
  key=$(jq -r '.psk // ""' "$req")
  valid_peer "$peer" && valid_cidr "$localSubnet" && valid_cidr "$remoteSubnet" ||
    die 'Invalid IPsec endpoint or traffic selector'
  valid_identity "$localId" && valid_identity "$remoteId" || die 'Invalid peer identities'
  [ "$localSubnet" != "$remoteSubnet" ] || die 'Local and remote subnet must differ'
  case "$enabled" in true|false) :;; *) die 'Invalid enabled state';; esac
  if [ -z "$key" ] && [ -f "$f" ]; then
    key=$(sed -n 's/^    secret = "\(.*\)"$/\1/p' "$f" | head -1)
  fi
  valid_key "$key" || die 'PSK must be 20-256 safe ASCII characters'
  mkdir -p -m 0700 "$DIR"
  tmp=$(mktemp "$DIR/.litefw-ipsec.XXXXXX")
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  {
    printf '# litefwm:peer=%s\n' "$peer"
    printf '# litefwm:localSubnet=%s\n' "$localSubnet"
    printf '# litefwm:remoteSubnet=%s\n' "$remoteSubnet"
    printf '# litefwm:localId=%s\n' "$localId"
    printf '# litefwm:remoteId=%s\n' "$remoteId"
    printf '# litefwm:enabled=%s\n' "$enabled"
    printf 'connections {\n  litefwm-%s {\n' "$name"
    printf '    version = 2\n    local_addrs = %%any\n    remote_addrs = %s\n' "$peer"
    printf '    proposals = aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048\n'
    printf '    local {\n      auth = psk\n      id = %s\n    }\n' "$localId"
    printf '    remote {\n      auth = psk\n      id = %s\n    }\n' "$remoteId"
    printf '    children {\n      litefwm-%s {\n' "$name"
    printf '        local_ts = %s\n        remote_ts = %s\n' "$localSubnet" "$remoteSubnet"
    printf '        esp_proposals = aes256gcm16-ecp384,aes256-sha256-modp2048\n'
    printf '        start_action = none\n        dpd_action = clear\n      }\n    }\n  }\n}\n'
    printf 'secrets {\n  ike-litefwm-%s {\n' "$name"
    printf '    id-1 = %s\n    id-2 = %s\n' "$localId" "$remoteId"
    printf '    secret = "%s"\n  }\n}\n' "$key"
  } > "$tmp"
  chmod 0600 "$tmp"
  # Disabled profiles use .disabled and cannot be loaded by conf.d/*.conf.
  ext=conf; [ "$enabled" = false ] && ext=disabled
  target="$DIR/litefwm-$name.$ext"
  backup=""
  if [ -f "$f" ]; then
    backup="$f.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$f" "$backup" || die 'Could not back up existing IPsec tunnel'
  fi
  mv "$tmp" "$target"
  [ "$f" = "$target" ] || rm -f "$f"
  # Never automatically start charon or initiate any tunnel on save.
  if running; then
    if ! swanctl --load-conns >/dev/null 2>&1 ||
       ! swanctl --load-creds >/dev/null 2>&1; then
      rm -f "$target"
      if [ -n "$backup" ]; then cp -p "$backup" "$f"; fi
      swanctl --load-conns >/dev/null 2>&1 || :
      die 'strongSwan rejected tunnel load; previous configuration restored'
    fi
  fi
  jq -n --arg id "$name" '{id:$id,saved:true,started:false}'
}
delete(){
  require_root
  name=$1; f=$(path_for "$name")
  [ -f "$f" ] || die 'IPsec tunnel not found'
  cp -p "$f" "$f.backup.$(date -u +%Y%m%dT%H%M%SZ)" || die 'IPsec backup failed'
  rm -f "$f"
  running && swanctl --load-conns >/dev/null 2>&1 || :
}
initiate(){
  require_root
  name=$1; f=$(path_for "$name"); [ -r "$f" ] || die 'Unknown IPsec tunnel'
  [ "$(field enabled "$f")" = true ] && [ "${f##*.}" = conf ] || die 'Enable tunnel before initiating'
  running || die 'Start IPsec service first'
  swanctl --initiate --child "litefwm-$name" --timeout 15
}
stop_tunnel(){
  require_root
  name=$1; f=$(path_for "$name"); [ -r "$f" ] || die 'Unknown IPsec tunnel'
  running || return 0
  swanctl --terminate --child "litefwm-$name" >/dev/null 2>&1 || :
}
service(){
  require_root
  case "$1" in
    start) rc-update add charon default >/dev/null 2>&1 || :; rc-service charon start;;
    stop) rc-service charon stop; rc-update del charon default >/dev/null 2>&1 || :;;
    restart) rc-service charon restart;;
    *) die 'Invalid IPsec service action';;
  esac
}
firewall(){
  running || return 0
  found=false
  for n in $(all_names); do
    [ -r "$DIR/litefwm-$n.conf" ] && found=true
  done
  [ "$found" = true ] || return 0
  # Inbound IKE/NAT-T/ESP only. Internal VPN traffic is default-deny.
  # Only the default-route WAN, not LAN management.
  inbound=$(ip -4 -j route show default 2>/dev/null | jq -r '.[0].dev // empty')
  safe_iface "$inbound" || return 0
  echo "-A LFW_MOD -i $inbound -p udp -m multiport --dports 500,4500 -m comment --comment lfw:module:ipsec -j ACCEPT"
  echo "-A LFW_MOD -i $inbound -p esp -m comment --comment lfw:module:ipsec -j ACCEPT"
}
install_module(){
  require_root
  apk add --no-cache strongswan strongswan-openrc >/dev/null
  installed || die 'StrongSwan installation incomplete'
  # Not enabled/started at installation.
  mkdir -p -m 0700 "$DIR"
}
uninstall_module(){
  require_root
  rc-service charon stop >/dev/null 2>&1 || :
  rc-update del charon default >/dev/null 2>&1 || :
  apk del strongswan-openrc strongswan >/dev/null 2>&1 || :
  # Never erase native credentials or configured tunnels.
}
case "${1:-}" in
  meta) meta;;
  installed) installed;;
  snapshot) snapshot;;
  firewall) firewall;;
  install) install_module;;
  uninstall) uninstall_module;;
  tunnel-save) save "$2";;
  tunnel-delete) delete "$2";;
  tunnel-start) initiate "$2";;
  tunnel-stop) stop_tunnel "$2";;
  service) service "${2:-}";;
  *) die 'Unknown IPsec module operation';;
esac
