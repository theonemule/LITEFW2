#!/bin/sh
# Idempotent scheduling preserving other root cron jobs.
set -eu
umask 077
cfg=${LFW_CF_LEGACY_CONF:-/etc/inadyn/litefw-cloudflare-legacy.json}
cronfile=${LFW_CF_CRON_FILE:-/etc/crontabs/root}
periodic=${LFW_CF_PERIODIC_FILE:-/etc/periodic/15min/litefw-cloudflare}
action=${1:-apply}
case "$action" in apply|remove) :;; *) echo 'Unknown Cloudflare scheduler action' >&2; exit 1;; esac
if [ "$action" = remove ]; then
  interval=15; enabled=false
else
  [ -r "$cfg" ] || { echo 'Cloudflare profile missing' >&2; exit 1; }
  interval=$(jq -r '.scheduleMinutes // 15' "$cfg")
  enabled=$(jq -r 'if .enabled==null then true else .enabled end' "$cfg")
fi
case "$interval" in 5|15|30|60) :;; *) echo 'Invalid Cloudflare interval' >&2; exit 1;; esac
case "$enabled" in true|false) :;; *) echo 'Invalid Cloudflare enabled state' >&2; exit 1;; esac
mkdir -p "$(dirname "$cronfile")"
[ -f "$cronfile" ] || : >"$cronfile"
tmp=$(mktemp "$cronfile.litefw.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
grep -v 'litefw-cloudflare-managed' "$cronfile" >"$tmp" || :
if [ "$enabled" = true ]; then
  case "$interval" in 60) cadence='0 * * * *';; *) cadence="*/$interval * * * *";; esac
  printf '%s\n' "$cadence /usr/lib/litefwm/modules/ddns/cloudflare-legacy.sh sync 2>&1 | logger -t litefw-ddns # litefw-cloudflare-managed" >>"$tmp"
fi
chmod 0600 "$tmp"
mv "$tmp" "$cronfile"
rm -f "$periodic"
if [ "$enabled" = true ]; then
  rc-update add crond default >/dev/null 2>&1 || :
  rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null
fi
echo "Cloudflare schedule saved: $enabled, every $interval minutes"
