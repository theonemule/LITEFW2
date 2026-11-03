#!/bin/sh
# LiteFW Cloudflare updater for pfSense Global API Key imports.
# Inadyn Cloudflare supports Bearer tokens, so this helper uses Cloudflare
# legacy HTTPS headers. Credentials never appear in arguments or logs.
set -eu
umask 077
CFG=${LFW_CF_LEGACY_CONF:-/etc/inadyn/litefw-cloudflare-legacy.json}
STATE=${LFW_CF_LEGACY_STATE:-/var/lib/litefwm/ddns-cloudflare-state.json}
action=${1:-check}
case "$action" in check|sync|force|status) :;; *) echo 'usage: cloudflare-legacy.sh [check|sync|force|status]' >&2; exit 2;; esac
if [ "$action" = status ]; then
  if [ -r "$CFG" ]; then
    jq -n --argjson hosts "$(jq '.hostnames' "$CFG")" --arg zone "$(jq -r '.zone' "$CFG")" \
      --argjson last "$(cat "$STATE" 2>/dev/null || echo '{}')" \
      '{configured:true,zone:$zone,hostnames:$hosts,last:$last}'
  else
    printf '%s\n' '{"configured":false,"hostnames":[]}'
  fi
  exit 0
fi
[ -r "$CFG" ] || { echo 'Cloudflare legacy DDNS is not configured' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo 'Cloudflare DDNS requires root' >&2; exit 1; }
jq -e '
  (.zone|type=="string" and test("^[A-Za-z0-9.-]+$")) and
  (.email|type=="string" and test("^[A-Za-z0-9._%+@-]+$")) and
  (.apiKey|type=="string" and test("^[A-Za-z0-9_-]{20,128}$")) and
  (.hostnames|type=="array" and length>0 and length<=20 and all(.[];type=="string" and test("^[A-Za-z0-9.-]+$")))
' "$CFG" >/dev/null || { echo 'Invalid Cloudflare DDNS profile configuration' >&2; exit 1; }
zone=$(jq -r .zone "$CFG")
email=$(jq -r .email "$CFG")
key=$(jq -r .apiKey "$CFG")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf 'header = "X-Auth-Email: %s"\nheader = "X-Auth-Key: %s"\nheader = "Content-Type: application/json"\n' \
  "$email" "$key" > "$tmp/curl-auth"
unset email key
cf_get() { curl -4 -fsS --proto '=https' --tlsv1.2 --connect-timeout 6 --max-time 20 \
  --config "$tmp/curl-auth" "https://api.cloudflare.com/client/v4/$1"; }
public=$(curl -4 -fsS --proto '=https' --tlsv1.2 --connect-timeout 6 --max-time 12 https://api.ipify.org)
printf '%s' "$public" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i!~/^[0-9]{1,3}$/ || $i+0>255) exit 1; exit 0} {exit 1}' ||
  { echo 'Public IPv4 check returned an invalid address' >&2; exit 1; }
cf_get "zones?name=$zone&per_page=2" > "$tmp/zone.json"
jq -e '.success==true and (.result|length)==1' "$tmp/zone.json" >/dev/null ||
  { echo 'Cloudflare zone lookup failed or was ambiguous' >&2; exit 1; }
zoneid=$(jq -r '.result[0].id' "$tmp/zone.json")
updated=0
skipped=0
mismatched=0
for hostname in $(jq -r '.hostnames[]' "$CFG"); do
  case "$hostname" in *."$zone") :;; *) echo "Hostname outside permitted zone: $hostname" >&2; exit 1;; esac
  cf_get "zones/$zoneid/dns_records?name=$hostname&per_page=20" > "$tmp/record.json"
  jq -e --arg host "$hostname" '
    .success==true and
    (.result|map(select(.name==$host))|length)==1 and
    (.result|map(select(.name==$host))[0].type)=="A"
  ' "$tmp/record.json" >/dev/null ||
    { echo "Expected one existing Cloudflare A record for $hostname (no CNAME or record changes attempted)" >&2; exit 1; }
  recordid=$(jq -r --arg host "$hostname" '.result|map(select(.name==$host))[0].id' "$tmp/record.json")
  current=$(jq -r --arg host "$hostname" '.result|map(select(.name==$host))[0].content' "$tmp/record.json")
  if [ "$action" = check ]; then
    if [ "$current" = "$public" ]; then skipped=$((skipped+1))
    else mismatched=$((mismatched+1)); fi
    continue
  fi
  if [ "$current" = "$public" ] && [ "$action" != force ]; then
    skipped=$((skipped+1))
    continue
  fi
  jq -n --arg ip "$public" '{content:$ip}' >"$tmp/patch.json"
  curl -4 -fsS --proto '=https' --tlsv1.2 --connect-timeout 6 --max-time 20 \
    --config "$tmp/curl-auth" --request PATCH --data-binary @"$tmp/patch.json" \
    "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$recordid" >"$tmp/response.json"
  jq -e --arg ip "$public" '.success==true and .result.type=="A" and .result.content==$ip' "$tmp/response.json" >/dev/null ||
    { echo "Cloudflare rejected update for $hostname" >&2; exit 1; }
  updated=$((updated+1))
done
mkdir -p "$(dirname "$STATE")"
jq -n --arg ip "$public" --arg date "$(date -u +%FT%TZ)" \
  --argjson updated "$updated" --argjson unchanged "$skipped" --argjson mismatched "$mismatched" \
  '{checkedAt:$date,publicIPv4:$ip,updated:$updated,unchanged:$unchanged,mismatched:$mismatched}' > "$tmp/state.json"
mv "$tmp/state.json" "$STATE"
chmod 0640 "$STATE"
printf 'Cloudflare DDNS: %s changed, %s unchanged, %s mismatched, public IPv4 %s\n' "$updated" "$skipped" "$mismatched" "$public"
