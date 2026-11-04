#!/bin/sh
# Tailscale connectivity module. Installing never enables or joins a tailnet.
set -eu
DIR=${LFW_MODULE_CONFIG_DIR:-/etc/litefw-addons}
CONF="$DIR/tailscale.json"
die(){ printf '%s\n' "$*" >&2; exit 1; }
root(){ [ "$(id -u)" = 0 ] || die 'Root privileges are required'; }
installed(){ command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1 && [ -f /etc/init.d/tailscale ]; }
running(){ rc-service tailscale status >/dev/null 2>&1; }
config(){ if [ -s "$CONF" ]; then cat "$CONF"; else printf '{}\n'; fi; }
validate(){
  jq -e 'type=="object" and
    ((.acceptRoutes//false)|type=="boolean") and
    ((.advertiseRoutes//[])|type=="array" and length<=12 and
       all(.[]; type=="string" and test("^([0-9]{1,3}[.]){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$"))) and
    ((.hostname//"")|type=="string" and length<=63 and test("^[A-Za-z0-9-]*$"))' "$1" >/dev/null ||
       die 'Invalid hostname, acceptRoutes or advertised IPv4 CIDR list'
  for prefix in $(jq -r '.advertiseRoutes[]?' "$1"); do
    for octet in $(printf '%s' "${prefix%/*}" | tr '.' ' '); do
       [ "$octet" -le 255 ] || die 'Invalid subnet address'
    done
  done
}
snapshot(){
  online=false; running && online=true
  state='{}'
  if [ "$online" = true ]; then state=$(tailscale status --json 2>/dev/null || printf '{}'); fi
  printf '%s' "$state" | jq -e 'type=="object"' >/dev/null 2>&1 || state='{}'
  settings=$(config)
  jq -n --argjson running "$online" --argjson settings "$settings" --argjson ts "$state" '
    {running:$running,configured:($settings|has("acceptRoutes") or has("advertiseRoutes") or has("hostname")),
    settings:($settings|del(.authKey,.token,.secret)),backendState:($ts.BackendState//"Stopped"),
    tailnet:($ts.CurrentTailnet.Name//""),addresses:($ts.Self.TailscaleIPs//[]),
    online:($ts.Self.Online//false)}'
}
save(){
  root
  [ -r "$1" ] || die 'Configuration file missing'
  validate "$1"
  mkdir -p "$DIR"; chmod 0700 "$DIR"
  f=$(mktemp "$DIR/.tailscale.XXXXXX") || die 'Cannot stage settings'
  chmod 0600 "$f"
  jq '{acceptRoutes:(.acceptRoutes//false),
    advertiseRoutes:(.advertiseRoutes//[]),hostname:(.hostname//"")}' "$1" >"$f"
  mv "$f" "$CONF"
  snapshot
}
install_module(){
  root
  apk add --no-cache tailscale tailscale-openrc || die 'Alpine Tailscale install failed'
  installed || die 'Tailscale client, daemon or OpenRC service missing after installation'
}
stop(){
  if running; then tailscale down >/dev/null 2>&1 || true; rc-service tailscale stop || die 'Cannot stop tailscaled'; fi
  rc-update del tailscale default >/dev/null 2>&1 || true
}
service_action(){
  root
  installed || die 'Install Tailscale first'
  case "$1" in
    start) rc-service tailscale start || die 'Cannot start tailscaled'; rc-update add tailscale default >/dev/null 2>&1 || true;;
    restart) rc-service tailscale restart || die 'Cannot restart tailscaled';;
    stop) stop;;
    *) die 'Expected start, restart or stop';;
  esac
  snapshot
}
connect(){
  root
  installed || die 'Install Tailscale first'
  [ -s "$CONF" ] || die 'Save Tailscale settings before connecting'
  [ -r "$1" ] || die 'Missing request'
  jq -e 'type=="object" and ((.authKey//"")|type=="string" and length<=256)' "$1" >/dev/null || die 'Invalid auth request'
  key=$(jq -r '.authKey // ""' "$1")
  [ -n "$key" ] || die 'An API auth key is required; use the local console for interactive login'
  printf '%s' "$key" | grep -Eq '^tskey-[A-Za-z0-9_-]{16,250}$' || die 'Invalid Tailscale auth key' 
  routes=$(jq -r '(.advertiseRoutes//[])|join(",")' "$CONF")
  accept=$(jq -r '.acceptRoutes//false' "$CONF")
  host=$(jq -r '.hostname//""' "$CONF")
  running || rc-service tailscale start || die 'Cannot start tailscaled'
  keyfile=''
  cleanup(){ [ -z "$keyfile" ] || rm -f "$keyfile"; }
  trap cleanup EXIT HUP INT TERM
  # Keep system DNS, default WAN route and firewall managed by LiteFW.
  set -- up --reset --accept-dns=false "--accept-routes=$accept" --netfilter-mode=off \
    --ssh=false --advertise-exit-node=false "--advertise-routes=$routes"
  [ -z "$host" ] || set -- "$@" "--hostname=$host"
  if [ -n "$key" ]; then
    keyfile=$(mktemp /tmp/.lfw-tailscale.XXXXXX) || die 'Could not create protected auth key file'
    chmod 0600 "$keyfile"
    printf '%s\n' "$key" >"$keyfile"
    set -- "$@" "--auth-key=file:$keyfile"
  fi
  unset key
  # Only explicit Connect action can join a tailnet.
  timeout 45 tailscale "$@" >/dev/null || die 'Tailscale connect failed or timed out; check auth key or tailnet approval'
  rc-update add tailscale default >/dev/null 2>&1 || true
  snapshot
}
disconnect(){
  root
  installed || die 'Install Tailscale first'
  if running; then tailscale down || die 'Could not disconnect'; fi
  snapshot
}
remove(){
  root
  stop
  apk del tailscale tailscale-openrc || die 'Unable to uninstall Tailscale'
  rm -f "$CONF"
}
case "${1:-}" in
 meta) jq -n '{id:"tailscale",name:"Tailscale",description:"Encrypted tailnet connectivity, optional subnet routing and remote-node access",category:"connectivity"}';;
 installed) installed;;
 snapshot) snapshot;;
 firewall) : ;; # No implicit traffic/management allow rule.
 validate) validate "${2:?configuration file required}";;
 install) install_module;;
 uninstall) remove;;
 configure) save "${2:?configuration file required}";;
 service) service_action "${2:?service action required}";;
 connect) connect "${2:?authentication body required}";;
 disconnect) disconnect;;
 *) die 'Unknown Tailscale operation';;
esac
