#!/bin/sh
# Cloudflare edit transaction: root-owned request file, no secrets in argv.
set -eu
umask 077
[ "$(id -u)" = 0 ] || { echo 'Root privileges required' >&2; exit 1; }
[ "$#" -eq 1 ] && [ -r "$1" ] || { echo 'Missing Cloudflare configuration request' >&2; exit 1; }
self=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
cfg=${LFW_CF_LEGACY_CONF:-/etc/inadyn/litefw-cloudflare-legacy.json}
mkdir -p "$(dirname "$cfg")"
working=$(mktemp -d "$(dirname "$cfg")/.litefw-cloudflare.XXXXXX")
trap 'rm -rf "$working"' EXIT HUP INT TERM
if [ -s "$cfg" ]; then cp "$cfg" "$working/prior.json"; else printf '{}\n' >"$working/prior.json"; fi
jq -n --slurpfile old "$working/prior.json" --slurpfile request "$1" '
  ($request[0]) as $req | ($old[0]) as $prev |
  {zone:$req.zone,email:$req.email,
   apiKey:(if ($req.apiKey // "") == "" then $prev.apiKey else $req.apiKey end),
   hostnames:$req.hostnames,
   scheduleMinutes:($req.scheduleMinutes|tonumber?),
   enabled:$req.enabled}
' >"$working/new.json"
jq -e '
  . as $p |
  ($p.zone | type=="string" and length<=253 and test("^[a-z0-9]+([a-z0-9.-]*[a-z0-9])?$")) and
  ($p.email | type=="string" and length<=254 and test("^[A-Za-z0-9._%+@-]+$") and contains("@")) and
  ($p.apiKey | type=="string" and test("^[A-Za-z0-9_-]{20,128}$")) and
  ($p.enabled | type=="boolean") and
  ([$p.scheduleMinutes] | all(.[]; .==5 or .==15 or .==30 or .==60)) and
  ($p.hostnames | type=="array" and length>=1 and length<=20 and (unique==.) and
    all(.[];
      type=="string" and length<=253 and test("^[a-z0-9]+([a-z0-9.-]*[a-z0-9])?$"))) and
  ([$p.hostnames[] | endswith("." + $p.zone)] | all)
' "$working/new.json" >/dev/null || {
  echo 'Invalid Cloudflare profile: check zone, A record names, email, credential and interval' >&2; exit 1;
}
chmod 0600 "$working/new.json"
# Read-only Cloudflare API validation; no public record is changed.
LFW_CF_LEGACY_CONF="$working/new.json" LFW_CF_LEGACY_STATE="$working/candidate-state.json" \
  "$self/cloudflare-legacy.sh" check >/dev/null ||
  { echo 'Cloudflare validation failed; existing settings unchanged' >&2; exit 1; }
if [ -f "$cfg" ]; then
  cp -p "$cfg" "$cfg.backup.$(date -u +%Y%m%dT%H%M%SZ).$$" ||
    { echo 'Could not back up previous Cloudflare profile' >&2; exit 1; }
fi
mv "$working/new.json" "$cfg"
chmod 0600 "$cfg"
if ! "$self/cloudflare-schedule.sh" >/dev/null; then
  cp -p "$working/prior.json" "$cfg"
  echo 'Cloudflare scheduling failed; profile restored' >&2
  exit 1
fi
jq -n --slurpfile profile "$cfg" '($profile[0]) as $p |
  {zone:$p.zone,hostnames:$p.hostnames,enabled:$p.enabled,scheduleMinutes:$p.scheduleMinutes,credentialConfigured:true}'
