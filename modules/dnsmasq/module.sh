#!/bin/sh
set -eu
# LiteFW's DNSMasq module is a managed DNS option, but the binary is also the
# appliance DHCP service. Switching DNS engines may never uninstall it.
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMMON="$SELF/../../lib/common.sh"
[ -r "$COMMON" ] || COMMON="$SELF/../../common.sh"
[ -r "$COMMON" ] || COMMON=/usr/lib/litefwm/common.sh
. "$COMMON"
meta(){ jq -n '{id:"dnsmasq",name:"DNSMasq",description:"Built-in DNS forwarding and local host records, sharing a daemon with DHCP. Choose BIND for authoritative zones.",category:"dns"}'; }
installed(){ command -v dnsmasq >/dev/null 2>&1 && [ -f /etc/init.d/dnsmasq ]; }
snapshot(){
  live=false
  rc-service dnsmasq status >/dev/null 2>&1 && live=true || :
  dns_enabled=true
  [ ! -f /etc/dnsmasq.d/05-litefwm-bind.conf ] || dns_enabled=false
  jq -n --argjson running "$live" --argjson dnsEnabled "$dns_enabled" '{running:$running,configured:true,dnsEnabled:$dnsEnabled}'
}
case "${1:-}" in
  meta) meta;;
  installed) installed;;
  snapshot) snapshot;;
  firewall) : ;;
  install|uninstall) die "DNSMasq provides appliance DHCP and cannot be removed or installed separately";;
  *) die "Unsupported DNSMasq module action";;
esac
