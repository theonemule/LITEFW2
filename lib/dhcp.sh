# shellcheck shell=sh
# DHCP server, reservations and DNS, all native dnsmasq configuration:
#   /etc/dnsmasq.d/00-litefwm.conf      base options (installed once)
#   /etc/dnsmasq.d/10-dns.conf          local domain, upstream servers, host records
#   /etc/dnsmasq.d/20-listen.conf       interfaces dnsmasq serves (= LAN segments)
#   /etc/dnsmasq.d/30-dhcp-IFACE.conf   DHCP server for one segment
#   /etc/dnsmasq.hosts.d/MAC            one static reservation (dhcp-hostsdir)
# Leases are read from dnsmasq's lease database.

dhcpd_file() { printf '%s/30-dhcp-%s.conf' "$LFW_DNSMASQ_DIR" "$1"; }
dhcpd_tag() { printf 'lfw_%s' "$1" | tr '.' '_'; }
dhcpd_exists() { [ -f "$(dhcpd_file "$1")" ]; }
dhcpd_remove() { rm -f "$(dhcpd_file "$1")"; }

dhcpd_read() { # IFACE -> JSON
  local _f
  _f=$(dhcpd_file "$1")
  if [ ! -f "$_f" ]; then echo '{"enabled":false}'; return; fi
  awk -F'[=,]' '
    function q(s){ gsub(/"/,"",s); return "\"" s "\"" }
    $1=="dhcp-range" { start=$3; end=$4; lease=$6 }
    $1=="dhcp-option" && $3=="option:router" { router=$4 }
    $1=="dhcp-option" && $3=="option:dns-server" { for(i=4;i<=NF;i++) dns=dns (dns?",":"") q($i) }
    $1=="dhcp-option" && $3=="option:domain-name" { domain=$4 }
    $1=="dhcp-option" && $3=="option:ntp-server" { for(i=4;i<=NF;i++) ntp=ntp (ntp?",":"") q($i) }
    END { printf "{\"enabled\":true,\"start\":%s,\"end\":%s,\"leaseTime\":%s,\"router\":%s,\"dns\":[%s],\"domain\":%s,\"ntp\":[%s]}\n",
          q(start), q(end), q(lease), q(router), dns, q(domain), ntp }' "$_f"
}

dhcpd_all() {
  local _o _f _i
  _o='{}'
  for _f in "$LFW_DNSMASQ_DIR"/30-dhcp-*.conf; do
    [ -e "$_f" ] || continue
    _i=${_f##*/30-dhcp-}; _i=${_i%.conf}
    _o=$(printf '%s' "$_o" | jq --arg i "$_i" --argjson v "$(dhcpd_read "$_i")" '.[$i]=$v')
  done
  printf '%s\n' "$_o"
}

# the interface address (CIDR) whose subnet contains IP, if any
iface_cidr_for() { # IFACE IP
  local _c
  for _c in $(iface_ips "$1"); do in_cidr "$2" "$_c" && { echo "$_c"; return 0; }; done; return 1
}

# dhcpd_fits IFACE: range still inside the interface's addresses
dhcpd_fits() {
  local _s _e _c
  _s=$(dhcpd_read "$1" | jq -r .start); _e=$(dhcpd_read "$1" | jq -r .end)
  _c=$(iface_cidr_for "$1" "$_s") || return 1
  in_cidr "$_e" "$_c"
}

# dhcpd.set {interface, enabled, start, end, leaseTime, router, dns:[], domain, ntp:[]}
op_dhcpd_set() {
  _i=$(jget interface); need_iface "$_i"
  if ! jbool enabled; then
    dhcpd_remove "$_i"
    fw_sync; dnsmasq_apply
    log_op "dhcpd.set $_i disabled"
    return 0
  fi
  [ "$(role_of "$_i")" = lan ] || die "the DHCP server runs on LAN segments; set $_i's role to LAN first"
  dhcp_running "$_i" && die "$_i gets its address by DHCP; give it a static address first"
  _s=$(jget start); _e=$(jget end)
  is_ipv4 "$_s" && is_ipv4 "$_e" || die "range start and end must be IPv4 addresses"
  _c=$(iface_cidr_for "$_i" "$_s") || die "$_s is not inside any address on $_i"
  in_cidr "$_e" "$_c" || die "$_e is not in the same subnet as $_s ($_c)"
  [ "$(ip2int "$_s")" -le "$(ip2int "$_e")" ] || die "range start must not be after range end"
  _own=${_c%/*}
  if [ "$(ip2int "$_own")" -ge "$(ip2int "$_s")" ] && [ "$(ip2int "$_own")" -le "$(ip2int "$_e")" ]; then
    die "the range includes the firewall's own address $_own"
  fi
  _lt=$(jget leaseTime); _lt=${_lt:-12h}; is_lease_time "$_lt" || die "invalid lease time (e.g. 3600, 30m, 12h, 7d)"
  _r=$(jget router); _r=${_r:-$_own}; is_ipv4 "$_r" || die "invalid gateway"
  _dns=$(jlist dns | tr '\n' ' '); [ -n "$_dns" ] || _dns=$_own
  for _d in $_dns; do is_ipv4 "$_d" || die "invalid DNS server $_d"; done
  _dom=$(jget domain); [ -z "$_dom" ] || is_fqdn "$_dom" || die "invalid domain"
  _ntp=$(jlist ntp | tr '\n' ' ')
  for _d in $_ntp; do is_ipv4 "$_d" || die "invalid NTP server $_d"; done
  _tag=$(dhcpd_tag "$_i")
  _t=$(mktemp)
  {
    echo "# LiteFWM DHCP server for $_i"
    echo "dhcp-range=set:$_tag,$_s,$_e,$(cidr_mask "${_c#*/}"),$_lt"
    echo "dhcp-option=tag:$_tag,option:router,$_r"
    echo "dhcp-option=tag:$_tag,option:dns-server,$(printf '%s' "$_dns" | sed 's/ *$//; s/ /,/g')"
    [ -z "$_dom" ] || echo "dhcp-option=tag:$_tag,option:domain-name,$_dom"
    [ -z "$_ntp" ] || echo "dhcp-option=tag:$_tag,option:ntp-server,$(printf '%s' "$_ntp" | sed 's/ *$//; s/ /,/g')"
  } >"$_t"
  _f=$(dhcpd_file "$_i"); _old=""
  [ ! -f "$_f" ] || { _old=$(mktemp); cp "$_f" "$_old"; }
  mkdir -p "$LFW_DNSMASQ_DIR"; install -m 0644 "$_t" "$_f"; rm -f "$_t"
  if ! dnsmasq_check; then
    if [ -n "$_old" ]; then mv "$_old" "$_f"; else rm -f "$_f"; fi
    die "dnsmasq rejected the configuration: $(dnsmasq_check_msg)"
  fi
  rm -f "$_old"
  fw_sync; dnsmasq_apply
  log_op "dhcpd.set $_i $_s-$_e lease=$_lt router=$_r dns=$_dns"
}

# dhcpd_rename FROM TO: the DHCP server follows the L3 endpoint
dhcpd_rename() {
  local _f _a _b
  _f=$(dhcpd_file "$1"); [ -f "$_f" ] || return 0
  _a=$(dhcpd_tag "$1"); _b=$(dhcpd_tag "$2")
  sed -e "s/:$_a,/:$_b,/g" -e "s/for $1\$/for $2/" "$_f" >"$(dhcpd_file "$2")"
  chmod 0644 "$(dhcpd_file "$2")"; rm -f "$_f"
}

# ---------------------------------------------------------------- leases & reservations
leases_json() {
  [ -r "$LFW_LEASES" ] || { echo '[]'; return; }
  awk '{ h=$4; if(h=="*") h="";
         printf "{\"expires\":%s,\"mac\":\"%s\",\"ip\":\"%s\",\"hostname\":\"%s\"}\n", ($1+0), tolower($2), $3, h }' "$LFW_LEASES" | jq -s .
}

reservations_json() {
  local _f
  for _f in "$LFW_HOSTS_DIR"/*; do
    [ -f "$_f" ] || continue
    awk -F, 'NF>=2 && $1 !~ /^#/ { printf "{\"mac\":\"%s\",\"ip\":\"%s\",\"hostname\":\"%s\"}\n", tolower($1), $2, $3 }' "$_f"
  done | jq -s .
}

res_file() { printf '%s/%s' "$LFW_HOSTS_DIR" "$(printf '%s' "$1" | tr ':' '-')"; }

# reservation.add {mac, ip, hostname}: also used to promote a lease.
op_reservation_add() {
  _mac=$(lower "$(jget mac)"); _ip=$(jget ip); _h=$(jget hostname)
  is_mac "$_mac" || die "invalid MAC address"
  is_ipv4 "$_ip" || die "invalid IP address"
  [ -z "$_h" ] || is_hostname "$_h" || die "invalid hostname (letters, digits, -)"
  # Reservations are configuration data, not permission to start DHCP.
  # A newly created reservation must fit a configured internal LAN subnet;
  # an existing imported reservation may be edited while its NIC is unassigned
  # as long as its IP does not change.  No DHCP scope is ever created here.
  _prior=$(reservations_json | jq -r --arg m "$_mac" '.[] | select(.mac==$m) | .ip' | head -n 1)
  _seg=""
  for _i in $(lan_ifaces); do
    iface_cidr_for "$_i" "$_ip" >/dev/null && _seg=$_i
  done
  if [ -z "$_seg" ]; then
    [ -n "$_prior" ] && [ "$_prior" = "$_ip" ] ||
      die "$_ip is outside all configured LAN subnets; assign the interface first"
  fi
  if [ -n "$_seg" ]; then
    for _c in $(iface_ips "$_seg"); do
      [ "${_c%/*}" != "$_ip" ] || die "$_ip is the firewall's own address"
    done
  fi
  _other=$(reservations_json | jq -r --arg ip "$_ip" --arg m "$_mac" '.[] | select(.ip==$ip and .mac!=$m) | .mac' | head -n 1)
  [ -z "$_other" ] || die "$_ip is already reserved for $_other"
  _now=$(date +%s)
  _lessee=$(leases_json | jq -r --arg ip "$_ip" --arg m "$_mac" --argjson now "$_now" '.[] | select(.ip==$ip and .mac!=$m and (.expires==0 or .expires>$now)) | .mac' | head -n 1)
  [ -z "$_lessee" ] || die "$_ip is currently leased to $_lessee"
  if [ -n "$_h" ]; then
    _hd=$(reservations_json | jq -r --arg h "$_h" --arg m "$_mac" '.[] | select((.hostname|ascii_downcase)==($h|ascii_downcase) and .mac!=$m) | .mac' | head -n 1)
    [ -z "$_hd" ] || die "hostname $_h is already used by $_hd"
  fi
  mkdir -p "$LFW_HOSTS_DIR"
  _t=$(mktemp)
  if [ -n "$_h" ]; then echo "$_mac,$_ip,$_h" >"$_t"; else echo "$_mac,$_ip" >"$_t"; fi
  install -m 0644 "$_t" "$(res_file "$_mac")"; rm -f "$_t"
  dnsmasq_reload
  log_op "reservation.add $_mac $_ip $_h"
}

op_reservation_delete() {
  _mac=$(lower "$(jget mac)"); is_mac "$_mac" || die "invalid MAC address"
  [ -f "$(res_file "$_mac")" ] || die "no reservation for $_mac"
  rm -f "$(res_file "$_mac")"
  dnsmasq_reload
  log_op "reservation.delete $_mac"
}

# ---------------------------------------------------------------- DNS
dns_file() { printf '%s/10-dns.conf' "$LFW_DNSMASQ_DIR"; }
dns_read() {
  local _f
  _f=$(dns_file)
  [ -f "$_f" ] || { echo '{"domain":"","upstream":[],"hosts":[]}'; return; }
  awk -F= '
    $1=="domain" { d=$2 }
    $1=="server" { s=s (s?",":"") "\"" $2 "\"" }
    $1=="host-record" { n=split($2,a,","); h=h (h?",":"") "{\"name\":\"" a[1] "\",\"ip\":\"" a[n] "\"}" }
    END { printf "{\"domain\":\"%s\",\"upstream\":[%s],\"hosts\":[%s]}\n", d, s, h }' "$_f"
}

# dns.set {domain, upstream:[ip...], hosts:[{name, ip}]}
op_dns_set() {
  _dom=$(jget domain); _dom=${_dom:-lan}
  is_fqdn "$_dom" || die "invalid local domain"
  _up=$(jlist upstream)
  for _s in $_up; do is_ipv4 "$_s" || die "invalid upstream DNS server $_s"; done
  _hosts=$(jq -r '(.hosts // [])[] | "\(.name)\t\(.ip)"' "$BODY")
  _tab=$(printf '\t')
  printf '%s\n' "$_hosts" | while IFS=$_tab read -r _n _a; do
    [ -n "$_n" ] || continue
    is_fqdn "$_n" || die "invalid host name $_n"
    is_ipv4 "$_a" || die "invalid address for $_n"
  done || exit 1
  _t=$(mktemp)
  {
    echo "# LiteFWM DNS settings"
    echo "domain=$_dom"
    echo "local=/$_dom/"
    echo "expand-hosts"
    if [ -n "$_up" ]; then
      echo "no-resolv"
      for _s in $_up; do echo "server=$_s"; done
    fi
    printf '%s\n' "$_hosts" | while IFS=$_tab read -r _n _a; do
      [ -n "$_n" ] || continue
      case "$_n" in *.*) echo "host-record=$_n,$_a";; *) echo "host-record=$_n,$_n.$_dom,$_a";; esac
    done
  } >"$_t"
  _f=$(dns_file); _old=""
  [ ! -f "$_f" ] || { _old=$(mktemp); cp "$_f" "$_old"; }
  install -m 0644 "$_t" "$_f"; rm -f "$_t"
  if ! dnsmasq_check; then
    if [ -n "$_old" ]; then mv "$_old" "$_f"; else rm -f "$_f"; fi
    die "dnsmasq rejected the configuration: $(dnsmasq_check_msg)"
  fi
  rm -f "$_old"
  dnsmasq_apply
  log_op "dns.set domain=$_dom upstream=$(printf '%s' "$_up" | tr '\n' ' ')"
}

# 20-listen.conf follows the LAN roles on the interfaces
dns_listen_sync() {
  local _t _i
  _t=$(mktemp)
  {
    echo "# LiteFWM: dnsmasq serves DNS/DHCP only on LAN segments (derived from interface roles)"
    echo "interface=lo"
    for _i in $(lan_ifaces); do echo "interface=$_i"; done
  } >"$_t"
  mkdir -p "$LFW_DNSMASQ_DIR"
  install -m 0644 "$_t" "$LFW_DNSMASQ_DIR/20-listen.conf"; rm -f "$_t"
}

dnsmasq_check() { dnsmasq --test --conf-file="$LFW_DNSMASQ_CONF" >/dev/null 2>&1; }
dnsmasq_check_msg() { dnsmasq --test --conf-file="$LFW_DNSMASQ_CONF" 2>&1 | head -n 3 | tr '\n' ' '; }
dnsmasq_apply() {
  dnsmasq_check || die "dnsmasq configuration invalid: $(dnsmasq_check_msg)"
  svc dnsmasq restart || svc dnsmasq start || warn "dnsmasq did not restart; check /var/log/messages"
}
dnsmasq_reload() {
  if svc dnsmasq status; then svc dnsmasq reload || svc dnsmasq restart || true; else svc dnsmasq start || true; fi
}
dnsmasq_running() { pidof dnsmasq >/dev/null 2>&1; }