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

CONF=/etc/bind/named.conf
ZONE_DIR=/var/bind/litefwm
ZONES_CONF=/etc/bind/litefwm-zones.conf
DNSMASQ_BIND_MARKER=/etc/dnsmasq.d/05-litefwm-bind.conf

meta(){ jq -n '{id:"bind",name:"BIND DNS",description:"Authoritative DNS zones with optional restricted recursion and forwarding.",category:"dns"}'; }
installed(){ command -v named >/dev/null 2>&1 && command -v named-checkconf >/dev/null 2>&1; }
running(){ command -v rc-service >/dev/null 2>&1 && rc-service named status >/dev/null 2>&1; }
setting(){ sed -n "s#^// litefwm:$1=##p" "$CONF" 2>/dev/null | head -1; }

valid_ipv4_or_cidr(){ valid_ipv4 "$1" || valid_cidr "$1"; }
valid_acl_csv(){
  [ -z "${1:-}" ] && return 0
  [ "$1" = any ] && return 0
  old=$IFS; IFS=,
  for x in $1; do valid_ipv4_or_cidr "$x" || { IFS=$old; return 1; }; done
  IFS=$old
}
valid_addr_csv(){
  [ -n "${1:-}" ] || return 1
  old=$IFS; IFS=,
  for x in $1; do valid_ipv4 "$x" || { IFS=$old; return 1; }; done
  IFS=$old
}
emit_acl(){
  v=$1; empty=$2
  if [ -z "$v" ]; then printf '%s' "$empty"; return; fi
  [ "$v" = any ] && { printf 'any;'; return; }
  old=$IFS; IFS=,
  for x in $v; do printf '%s; ' "$x"; done
  IFS=$old
}
restart_dnsmasq_if_running(){
  if command -v rc-service >/dev/null 2>&1 && rc-service dnsmasq status >/dev/null 2>&1; then
    dnsmasq --test >/dev/null
    rc-service dnsmasq restart >/dev/null
  fi
}
claim_dns(){
  mkdir -p "$(dirname "$DNSMASQ_BIND_MARKER")"
  printf '%s\n' '# BIND owns port 53 while this module is configured' 'port=0' > "$DNSMASQ_BIND_MARKER"
  restart_dnsmasq_if_running
}
release_dns(){
  rm -f "$DNSMASQ_BIND_MARKER"
  restart_dnsmasq_if_running
}
restart_named(){
  named-checkconf "$CONF"
  named-checkconf -z "$CONF" >/dev/null
  rc-update add named default >/dev/null 2>&1 || true
  if running; then rc-service named restart >/dev/null; else rc-service named start >/dev/null; fi
}
settings_set(){
  require_root
  listen=$1; query=$2; transfer=$3; recurse=$4; recursive_clients=$5; forwarders=$6
  valid_addr_csv "$listen" || die "Listen addresses must be IPv4 addresses"
  valid_acl_csv "$query" || die "Invalid allow-query ACL"
  valid_acl_csv "$transfer" || die "Invalid allow-transfer ACL"
  case "$recurse" in true|false) ;; *) die "Invalid recursion setting";; esac
  valid_acl_csv "$recursive_clients" || die "Invalid recursion ACL"
  valid_ipv4_csv "$forwarders" || die "Invalid forwarders"
  if [ "$recurse" = true ]; then
    [ -n "$recursive_clients" ] || die "Recursive clients are required when recursion is enabled"
    [ "$recursive_clients" != any ] || die "Open recursion is not allowed"
    case ",$recursive_clients," in *,0.0.0.0/0,*) die "Open recursion is not allowed";; esac
  fi
  mkdir -p /etc/bind "$ZONE_DIR"
  touch "$ZONES_CONF"
  tmp=$(mktemp)
  {
    echo "// LiteFWM native BIND configuration"
    echo "// litefwm:listen=$listen"
    echo "// litefwm:query=$query"
    echo "// litefwm:transfer=$transfer"
    echo "// litefwm:recursion=$recurse"
    echo "// litefwm:recursive-clients=$recursive_clients"
    echo "// litefwm:forwarders=$forwarders"
    echo "options {"
    echo '  directory "/var/bind";'
    printf '  listen-on { '; old=$IFS; IFS=,; for x in $listen; do printf '%s; ' "$x"; done; IFS=$old; echo '};'
    echo '  listen-on-v6 { none; };'
    printf '  allow-query { '; emit_acl "$query" 'any;'; echo ' };'
    printf '  allow-transfer { '; emit_acl "$transfer" 'none;'; echo ' };'
    echo '  pid-file "/var/run/named/named.pid";'
    if [ "$recurse" = true ]; then
      echo '  recursion yes;'
      printf '  allow-recursion { '; emit_acl "$recursive_clients" 'none;'; echo ' };'
      if [ -n "$forwarders" ]; then
        printf '  forwarders { '; old=$IFS; IFS=,; for x in $forwarders; do printf '%s; ' "$x"; done; IFS=$old; echo '};'
      fi
    else
      echo '  recursion no;'
      echo '  allow-recursion { none; };'
    fi
    echo '};'
    echo "include \"$ZONES_CONF\";"
  } > "$tmp"
  named-checkconf "$tmp"
  named-checkconf -z "$tmp" >/dev/null
  mv "$tmp" "$CONF"
  chown root:named "$CONF"
  chmod 0640 "$CONF"
  claim_dns
  restart_named
}
rebuild_zones(){
  mkdir -p "$ZONE_DIR" /etc/bind
  tmp=$(mktemp)
  {
    echo "// LiteFWM zone declarations"
    for f in "$ZONE_DIR"/*.zone; do
      [ -r "$f" ] || continue
      z=$(sed -n 's/^; litefwm-zone://p' "$f" | head -1)
      [ -n "$z" ] || continue
      echo "zone \"$z\" IN {"
      echo "  type master;"
      echo "  file \"$f\";"
      echo "};"
    done
  } > "$tmp"
  mv "$tmp" "$ZONES_CONF"
  chown root:named "$ZONES_CONF"
  chmod 0640 "$ZONES_CONF"
}
zone_file(){
  z=$1
  valid_dns_name "$z" || die "Invalid zone name"
  printf '%s/%s.zone\n' "$ZONE_DIR" "$(printf '%s' "$z" | tr '[:upper:]' '[:lower:]')"
}
fqdn(){
  v=$1
  [ "$v" = @ ] && { printf '@'; return; }
  case "$v" in *.) printf '%s' "$v";; *) printf '%s.' "$v";; esac
}
valid_owner(){
  v=$1
  [ "$v" = @ ] && return 0
  printf '%s' "$v" | grep -Eq '^(\*\.)?[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?$'
}
next_serial(){
  old=$1; now=$(date +%s)
  [ "$old" -ge "$now" ] 2>/dev/null && echo $((old+1)) || echo "$now"
}
bump_serial(){
  serial_file=$1
  serial_old=$(awk '/; serial/{print $1;exit}' "$serial_file")
  [ -n "$serial_old" ] || serial_old=1
  serial_new=$(next_serial "$serial_old")
  awk -v old="$serial_old" -v new="$serial_new" 'BEGIN{done=0} {if(!done && $1==old && $0~/; serial/){sub(old,new);done=1} print}' "$serial_file" > "$serial_file.serial"
  mv "$serial_file.serial" "$serial_file"
}
zone_add(){
  require_root
  zone=$1; ns=$2; nsaddr=$3; admin=$4; ttl=$5; refresh=$6; retry=$7; expire=$8; minimum=$9
  valid_dns_name "$zone" || die "Invalid zone"
  valid_dns_name "$(printf '%s' "$ns" | sed 's/[.]$//')" || die "Invalid primary nameserver"
  valid_dns_name "$(printf '%s' "$admin" | sed 's/[.]$//')" || die "Invalid SOA administrator"
  for n in "$ttl" "$refresh" "$retry" "$expire" "$minimum"; do
    case "$n" in ''|*[!0-9]*) die "SOA timers must be numeric";; esac
  done
  zbase=$(printf '%s' "$zone" | sed 's/[.]$//' | tr '[:upper:]' '[:lower:]')
  nsbase=$(printf '%s' "$ns" | sed 's/[.]$//' | tr '[:upper:]' '[:lower:]')
  in_zone=false
  case "$nsbase" in
    "$zbase"|*."$zbase") in_zone=true;;
  esac
  if [ "$in_zone" = true ]; then
    [ -n "$nsaddr" ] || die "Primary NS IPv4 address is required when the nameserver is inside the zone"
    valid_ipv4 "$nsaddr" || die "Invalid primary NS IPv4 address"
  elif [ -n "$nsaddr" ]; then
    valid_ipv4 "$nsaddr" || die "Invalid primary NS IPv4 address"
  fi
  f=$(zone_file "$zone")
  [ ! -e "$f" ] || die "Zone already exists"
  mkdir -p "$ZONE_DIR"
  serial=$(date +%s)
  tmp=$(mktemp "$ZONE_DIR/.zone.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  {
    echo "; litefwm-zone:$zone"
    echo "\$TTL $ttl"
    echo "@ IN SOA $(fqdn "$ns") $(fqdn "$admin") ("
    echo "  $serial ; serial"
    echo "  $refresh ; refresh"
    echo "  $retry ; retry"
    echo "  $expire ; expire"
    echo "  $minimum ; minimum"
    echo ")"
    echo "@ $ttl IN NS $(fqdn "$ns") ; litefwm-record:apex-ns"
    if [ "$in_zone" = true ]; then
      echo "$(fqdn "$ns") $ttl IN A $nsaddr ; litefwm-record:apex-ns-address"
    fi
  } > "$tmp"
  named-checkzone "$zone" "$tmp" >/dev/null
  mv "$tmp" "$f"
  trap - EXIT INT TERM
  chown root:named "$f"
  chmod 0640 "$f"
  rebuild_zones
  restart_named
}

zone_delete(){
  require_root
  f=$(zone_file "$1")
  rm -f "$f"
  rebuild_zones
  restart_named
}
record_add(){
  require_root
  zone=$1; owner=$2; type=$(printf '%s' "$3"|tr '[:lower:]' '[:upper:]'); value=$4; ttl=$5; priority=${6:-}
  f=$(zone_file "$zone"); [ -r "$f" ] || die "Zone does not exist"
  valid_owner "$owner" || die "Invalid record name"
  case "$ttl" in ''|*[!0-9]*) die "TTL must be numeric";; esac
  case "$type" in
    A) valid_ipv4 "$value" || die "Invalid A record"; rdata=$value;;
    AAAA) printf '%s' "$value" | grep -Eq '^[0-9A-Fa-f:]+$' || die "Invalid AAAA record"; rdata=$value;;
    CNAME|NS|PTR) valid_dns_name "${value%.}" || die "Invalid hostname target"; rdata=$(fqdn "$value");;
    MX)
      case "$priority" in ''|*[!0-9]*) die "MX priority is required";; esac
      valid_dns_name "${value%.}" || die "Invalid MX target"
      rdata="$priority $(fqdn "$value")"
      ;;
    TXT)
      clean=$(printf '%s' "$value" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')
      rdata="\"$clean\""
      ;;
    *) die "Unsupported record type";;
  esac
  id="$(date +%s)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  cp "$f" "$f.tmp"
  printf '%s %s IN %s %s ; litefwm-record:%s\n' "$owner" "$ttl" "$type" "$rdata" "$id" >> "$f.tmp"
  bump_serial "$f.tmp"
  named-checkzone "$zone" "$f.tmp" >/dev/null
  mv "$f.tmp" "$f"
  restart_named
  jq -n --arg id "$id" '{ok:true,id:$id}'
}
record_delete(){
  require_root
  zone=$1; id=$2
  case "$id" in apex-ns*) die "The zone primary NS records are managed by LiteFWM";; esac
  f=$(zone_file "$zone"); [ -r "$f" ] || die "Zone does not exist"
  grep -q "; litefwm-record:$id$" "$f" || die "Record not found"
  grep -v "; litefwm-record:$id$" "$f" > "$f.tmp"
  bump_serial "$f.tmp"
  named-checkzone "$zone" "$f.tmp" >/dev/null
  mv "$f.tmp" "$f"
  restart_named
}
zones_json(){
  {
    for f in "$ZONE_DIR"/*.zone; do
      [ -r "$f" ] || continue
      zone=$(sed -n 's/^; litefwm-zone://p' "$f"|head -1)
      [ -n "$zone" ] || continue
      serial=$(awk '/; serial/{print $1;exit}' "$f")
      records=$(
        awk '
          /; litefwm-record:/ {
            id=$0; sub(/^.*; litefwm-record:/,"",id)
            line=$0; sub(/[[:space:]]*; litefwm-record:.*$/,"",line)
            print id "\t" line
          }' "$f" |
        while IFS="$(printf '\t')" read -r id line; do
          [ -n "$id" ] || continue
          jq -n --arg id "$id" --arg text "$line" '{id:$id,text:$text}'
        done | jq -s .
      )
      jq -n --arg name "$zone" --arg serial "$serial" --argjson records "$records" '{name:$name,serial:$serial,records:$records}'
    done
  } | jq -s .
}
snapshot(){
  run=false; running && run=true
  if [ ! -r "$CONF" ]; then
    jq -n --argjson running "$run" '{running:$running,configured:false,zones:[]}'
    return
  fi
  listen=$(setting listen); query=$(setting query); transfer=$(setting transfer); rec=$(setting recursion)
  clients=$(setting recursive-clients); forwarders=$(setting forwarders)
  jq -n --argjson running "$run" --arg listen "$listen" --arg query "$query" --arg transfer "$transfer" \
    --argjson recursion "${rec:-false}" --arg clients "$clients" --arg forwarders "$forwarders" \
    --argjson zones "$(zones_json)" \
    '{running:$running,configured:true,listenAddresses:($listen|split(",")|map(select(length>0))),allowQuery:($query|split(",")|map(select(length>0))),allowTransfer:($transfer|split(",")|map(select(length>0))),recursion:$recursion,recursiveClients:($clients|split(",")|map(select(length>0))),forwarders:($forwarders|split(",")|map(select(length>0))),zones:$zones}'
}
firewall(){
  [ -r "$CONF" ] || return 0
  running || return 0
  listen=$(setting listen)
  old=$IFS; IFS=,
  for a in $listen; do
    [ "$a" = 127.0.0.1 ] && continue
    if [ "$a" = 0.0.0.0 ]; then
      echo '-A LFW_MOD -p udp -m udp --dport 53 -m comment --comment lfw:module:bind:udp -j ACCEPT'
      echo '-A LFW_MOD -p tcp -m tcp --dport 53 -m comment --comment lfw:module:bind:tcp -j ACCEPT'
    else
      printf '%s\n' "-A LFW_MOD -d $a -p udp -m udp --dport 53 -m comment --comment lfw:module:bind:udp -j ACCEPT"
      printf '%s\n' "-A LFW_MOD -d $a -p tcp -m tcp --dport 53 -m comment --comment lfw:module:bind:tcp -j ACCEPT"
    fi
  done
  IFS=$old
}
install_module(){
  require_root
  apk add --no-cache bind bind-tools bind-openrc >/dev/null
  mkdir -p "$ZONE_DIR" /etc/bind
  touch "$ZONES_CONF"
  chown -R root:named /etc/bind "$ZONE_DIR" 2>/dev/null || true
  chmod 0750 /etc/bind
  [ ! -e /etc/bind/rndc.key ] || chmod 0640 /etc/bind/rndc.key
  chown root:named "$ZONES_CONF"
  chmod 0640 "$ZONES_CONF"
}
uninstall_module(){
  require_root
  rc-service named stop >/dev/null 2>&1 || true
  rc-update del named default >/dev/null 2>&1 || true
  release_dns
  apk del bind-openrc bind-tools bind >/dev/null 2>&1 || true
  rm -rf /etc/bind "$ZONE_DIR"
}
case "${1:-}" in
  meta) meta;;
  installed) installed;;
  install) install_module;;
  uninstall) uninstall_module;;
  snapshot) snapshot;;
  firewall) firewall;;
  settings-set) settings_set "${2:?LISTEN}" "${3:-any}" "${4:-}" "${5:-false}" "${6:-}" "${7:-}";;
  zone-add) zone_add "${2:?ZONE}" "${3:?NS}" "${4:-}" "${5:?ADMIN}" "${6:-3600}" "${7:-3600}" "${8:-600}" "${9:-1209600}" "${10:-300}";;
  zone-delete) zone_delete "${2:?ZONE}";;
  record-add) record_add "${2:?ZONE}" "${3:?NAME}" "${4:?TYPE}" "${5:?VALUE}" "${6:-300}" "${7:-}";;
  record-delete) record_delete "${2:?ZONE}" "${3:?ID}";;
  service)
    case "${2:-}" in
      start) [ -r "$CONF" ] || die "Configure BIND first"; claim_dns; restart_named;;
      stop) rc-service named stop; rc-update del named default >/dev/null 2>&1 || true; release_dns;;
      restart) claim_dns; restart_named;;
      *) die "service requires start, stop, or restart";;
    esac
    ;;
  *) echo "Unknown BIND module action" >&2; exit 2;;
esac
