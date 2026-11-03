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

CONF=${LFW_INADYN_CONF:-/etc/inadyn/inadyn.conf}
CFHELPER="$SELF/cloudflare-legacy.sh"
cf_status(){
  if [ -x "$CFHELPER" ]; then "$CFHELPER" status
  else printf '%s\n' '{"configured":false,"hostnames":[]}'; fi
}

meta(){ jq -n '{id:"ddns",name:"Dynamic DNS",description:"Lightweight inadyn client for common DDNS providers and custom update endpoints.",category:"network-service"}'; }
installed(){ command -v inadyn >/dev/null 2>&1 && [ -f /etc/init.d/inadyn ]; }
running(){ command -v rc-service >/dev/null 2>&1 && rc-service inadyn status >/dev/null 2>&1; }
field(){ sed -n "s/^# litefwm:$1=//p" "$CONF" 2>/dev/null | head -1; }
valid_provider(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@-]+$'; }
escape_value(){ printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
valid_hosts(){
  old=$IFS; IFS=,
  for h in $1; do valid_dns_name "$h" || { IFS=$old; return 1; }; done
  IFS=$old
}
old_secret(){ sed -n 's/^[[:space:]]*password[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$CONF" 2>/dev/null | head -1; }
providers(){
  if inadyn --list-providers --json >/tmp/litefwm-inadyn-providers.$$ 2>/dev/null; then
    cat /tmp/litefwm-inadyn-providers.$$; rm -f /tmp/litefwm-inadyn-providers.$$
  else
    jq -n '["default@cloudflare.com","default@duckdns.org","default@no-ip.com","default@dyndns.org","default@he.net","default@dynu.com","default@namecheap.com","default@freedns.afraid.org","custom"]'
  fi
}
configure(){
  require_root
  provider=$1; hosts=$2; user=$3; secret=$4; period=$5; iface=$6
  check_server=${7:-}; check_path=${8:-}; update_server=${9:-}; shift 9
  update_path=${1:-}; custom_ssl=${2:-true}
  valid_provider "$provider" || die "Invalid provider"
  [ -n "$hosts" ] && valid_hosts "$hosts" || die "Invalid hostname list"
  case "$period" in ''|*[!0-9]*) die "Period must be numeric";; esac
  [ "$period" -ge 60 ] || die "Minimum update period is 60 seconds"
  [ -z "$iface" ] || { safe_iface "$iface" && ip link show dev "$iface" >/dev/null 2>&1; } || die "Invalid source interface"
  case "$custom_ssl" in true|false) ;; *) die "Invalid SSL setting";; esac
  if [ -z "$secret" ] && [ -r "$CONF" ] && grep -q "^# litefwm:provider=" "$CONF"; then secret=$(old_secret); fi
  [ -n "$secret" ] || die "Provider credential is required"

  mkdir -p /etc/inadyn
  tmp=$(mktemp)
  {
    echo "# LiteFWM native inadyn configuration"
    echo "# litefwm:provider=$provider"
    echo "# litefwm:hosts=$hosts"
    echo "# litefwm:username=$(escape_value "$user")"
    echo "# litefwm:period=$period"
    echo "# litefwm:interface=$iface"
    echo "# litefwm:custom-check-server=$check_server"
    echo "# litefwm:custom-check-path=$check_path"
    echo "# litefwm:custom-update-server=$update_server"
    echo "# litefwm:custom-update-path=$update_path"
    echo "# litefwm:custom-ssl=$custom_ssl"
    echo "period = $period"
    [ -z "$iface" ] || echo "iface = \"$(escape_value "$iface")\""
    if [ "$provider" = custom ]; then
      [ -n "$check_server" ] && [ -n "$update_server" ] && [ -n "$update_path" ] || die "Custom provider requires check and update endpoints"
      echo "custom litefwm {"
      echo "  username = \"$(escape_value "$user")\""
      echo "  password = \"$(escape_value "$secret")\""
      echo "  checkip-server = \"$(escape_value "$check_server")\""
      echo "  checkip-path = \"$(escape_value "${check_path:-/}")\""
      echo "  ddns-server = \"$(escape_value "$update_server")\""
      echo "  ddns-path = \"$(escape_value "$update_path")\""
      echo "  ssl = $custom_ssl"
    else
      echo "provider $provider {"
      [ -z "$user" ] || echo "  username = \"$(escape_value "$user")\""
      echo "  password = \"$(escape_value "$secret")\""
    fi
    printf '  hostname = { '
    old=$IFS; IFS=,; first=true
    for h in $hosts; do
      [ "$first" = true ] || printf ', '
      printf '"%s"' "$(escape_value "$h")"
      first=false
    done
    IFS=$old
    echo ' }'
    echo '}'
  } > "$tmp"
  chmod 0600 "$tmp"
  inadyn --check-config -f "$tmp" >/dev/null
  if [ -f "$CONF" ]; then
    # Native/package-provided config must not be silently discarded.
    cp -p "$CONF" "$CONF.litefw-backup.$(date -u +%Y%m%dT%H%M%SZ)" || die "Failed to back up existing inadyn configuration"
  fi
  mv "$tmp" "$CONF"
  chown root:inadyn "$CONF" 2>/dev/null || true
  chmod 0640 "$CONF"
  rc-update add inadyn default >/dev/null 2>&1 || true
  if running; then rc-service inadyn restart; else rc-service inadyn start; fi
}
snapshot(){
  run=false; running && run=true
  cf=$(cf_status)
  # Alpine's inadyn package ships a sample /etc/inadyn/inadyn.conf. It is
  # not an appliance-managed provider configuration; do not attempt to parse
  # nonexistent LiteFW metadata (e.g. period="" -> jq tonumber failure).
  if [ ! -r "$CONF" ] || ! grep -q '^# litefwm:provider=' "$CONF"; then
    native=false
    [ ! -f "$CONF" ] || native=true
    jq -n --argjson running "$run" --argjson nativeConfig "$native" --argjson cloudflare "$cf" '{running:$running,configured:false,nativeConfig:$nativeConfig,cloudflare:$cloudflare}'
    return
  fi
  provider=$(field provider); hosts=$(field hosts); user=$(field username); period=$(field period); iface=$(field interface)
  case "$period" in ''|*[!0-9]*) period=300;; esac
  secret=false; grep -q '^[[:space:]]*password[[:space:]]*=' "$CONF" && secret=true
  ssl=$(field custom-ssl); [ -n "$ssl" ] || ssl=true
  jq -n --argjson running "$run" --arg provider "$provider" --arg hosts "$hosts" --arg username "$user" \
    --arg period "$period" --arg interface "$iface" --argjson credentialConfigured "$secret" \
    --arg checkServer "$(field custom-check-server)" --arg checkPath "$(field custom-check-path)" \
    --arg updateServer "$(field custom-update-server)" --arg updatePath "$(field custom-update-path)" \
    --argjson customSsl "$ssl" --argjson cloudflare "$cf" \
    '{cloudflare:$cloudflare,running:$running,configured:true,provider:$provider,hostnames:($hosts|split(",")|map(select(length>0))),username:$username,period:($period|tonumber),interface:$interface,credentialConfigured:$credentialConfigured,custom:{checkServer:$checkServer,checkPath:$checkPath,updateServer:$updateServer,updatePath:$updatePath,ssl:$customSsl}}'
}
force_update(){
  require_root
  [ -r "$CONF" ] || die "Dynamic DNS is not configured"
  mkdir -p /var/cache/inadyn
  chown inadyn:inadyn /var/cache/inadyn 2>/dev/null || true
  inadyn --once --force -f "$CONF" --cache-dir /var/cache/inadyn
}
install_module(){
  require_root
  _log=$(mktemp)
  if ! apk add --no-cache inadyn inadyn-openrc >"$_log" 2>&1; then
    _detail=$(tail -n 8 "$_log")
    rm -f "$_log"
    die "Dynamic DNS installation failed. Check Alpine community repository and offline/online package availability: $_detail"
  fi
  rm -f "$_log"
  installed || die "Dynamic DNS packages installed but the inadyn executable or OpenRC service is missing"
  mkdir -p /etc/inadyn
}
uninstall_module(){
  require_root
  rc-service inadyn stop >/dev/null 2>&1 || true
  rc-update del inadyn default >/dev/null 2>&1 || true
  apk del inadyn-openrc inadyn >/dev/null 2>&1 || true
  [ ! -x "$SELF/cloudflare-schedule.sh" ] || "$SELF/cloudflare-schedule.sh" remove >/dev/null 2>&1 || true
  rm -rf /etc/inadyn /var/cache/inadyn
}
case "${1:-}" in
  meta) meta;;
  installed) installed;;
  install) install_module;;
  uninstall) uninstall_module;;
  snapshot) snapshot;;
  providers) providers;;
  firewall) : ;;
  configure) shift; configure "$@";;
  force-update) force_update;;
  cloudflare-check) require_root; [ -x "$CFHELPER" ] || die "Cloudflare helper missing"; "$CFHELPER" check;;
  cloudflare-update) require_root; [ -x "$CFHELPER" ] || die "Cloudflare helper missing"; "$CFHELPER" force;;
  cloudflare-configure) require_root; [ -x "$SELF/cloudflare-configure.sh" ] || die "Cloudflare settings handler missing"; "$SELF/cloudflare-configure.sh" "$2";;
  service)
    case "${2:-}" in
      start) [ -r "$CONF" ] || die "Configure Dynamic DNS first"; rc-update add inadyn default >/dev/null 2>&1 || true; rc-service inadyn start;;
      stop) rc-service inadyn stop; rc-update del inadyn default >/dev/null 2>&1 || true;;
      restart) rc-service inadyn restart;;
      *) die "service requires start, stop, or restart";;
    esac
    ;;
  *) echo "Unknown Dynamic DNS module action" >&2; exit 2;;
esac
