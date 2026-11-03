#!/bin/sh
# Health-driven multi-WAN default route. Never changes a route if no gateway
# is reachable on its own physical interface. Used by explicit Start and cron.
set -eu
CONF=${LFW_MODULE_CONFIG_DIR:-/etc/litefw-addons}/multiwan.json
[ -r "$CONF" ] || exit 0
[ "$(jq -r '.enabled // false' "$CONF")" = true ] || exit 0
choice=$(
  jq -r '.uplinks | sort_by(.priority)[] | [.interface,.gateway] | @tsv' "$CONF" |
  while IFS="$(printf '\t')" read -r dev gw; do
    [ -e "/sys/class/net/$dev" ] || continue
    ip -o link show dev "$dev" 2>/dev/null | grep -Eq '<[^>]*UP([,>])' || continue
    if ping -n -c 1 -W 2 -I "$dev" "$gw" >/dev/null 2>&1; then
      printf '%s %s\n' "$dev" "$gw"
      break
    fi
  done
)
[ -n "$choice" ] || { echo 'No healthy WAN gateway; default route preserved' >&2; exit 1; }
set -- $choice
dev=$1; gw=$2
current=$(ip -4 route show default | head -1)
case "$current" in *"via $gw dev $dev"*) exit 0;; esac
mkdir -p /run/litefwm
if [ ! -s /run/litefwm/multiwan-original-route ]; then
  [ -n "$current" ] && printf '%s\n' "$current" >/run/litefwm/multiwan-original-route
fi
ip -4 route replace default via "$gw" dev "$dev" ||
  { echo 'Failed to activate a healthy WAN route; previous route unchanged' >&2; exit 1; }
logger -t litefw-multiwan "Default route selected: $dev via $gw" 2>/dev/null || true
