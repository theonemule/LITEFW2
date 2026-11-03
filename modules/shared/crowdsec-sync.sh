#!/bin/sh
# CrowdSec local-LAPI decision bridge to LiteFW's existing iptables/ipset rules.
# No second firewall rule owner: the module emits LiteFW-managed rules.
set -eu
DIR=${LFW_MODULE_CONFIG_DIR:-/etc/litefw-addons}
[ -r "$DIR/crowdsec.json" ] || exit 0
[ "$(jq -r '.enabled // false' "$DIR/crowdsec.json")" = true ] || exit 0
COMMON=/usr/lib/litefwm/common.sh
[ -r "$COMMON" ] || COMMON="$(dirname "$0")/../../lib/common.sh"
. "$COMMON"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
# A failed CrowdSec API query never flushes an existing IP set.
cscli decisions list --type ban --all --limit 0 --output json >"$tmp/decisions" ||
  die 'Could not query CrowdSec decisions; existing blockset preserved'
jq -e 'type=="array" or .==null' "$tmp/decisions" >/dev/null ||
  die 'Unexpected CrowdSec decisions response; existing blockset preserved'
jq -r '(if type=="array" then . else [] end)[] | select((.type//""|ascii_downcase)=="ban") |
  select((.scope//""|ascii_downcase)=="ip" or (.scope//""|ascii_downcase)=="range") | .value' "$tmp/decisions" |
  sort -u >"$tmp/candidates"
: >"$tmp/validated"
while IFS= read -r source; do
  is_addr "$source" || continue
  printf '%s\n' "$source" >>"$tmp/validated"
done <"$tmp/candidates"
ipset create litefw_cs4 hash:net family inet maxelem 300000 -exist
ipset create litefw_cs4_tmp hash:net family inet maxelem 300000 -exist
ipset flush litefw_cs4_tmp
sed 's/^/add litefw_cs4_tmp /' "$tmp/validated" | ipset restore ||
  die 'Could not load CrowdSec decisions; previous blockset preserved'
ipset swap litefw_cs4_tmp litefw_cs4
ipset destroy litefw_cs4_tmp
mkdir -p "$DIR"
ipset save litefw_cs4 >"$DIR/crowdsec.ipset"
chmod 0600 "$DIR/crowdsec.ipset"
printf 'Synced %s active IPv4 bans\n' "$(wc -l <"$tmp/validated")"
