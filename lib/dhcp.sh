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

# DHCP scope settings are stored separately from the live dnsmasq scope.
# A disabled scope remains editable, but emits NO DHCP range or listener.
dhcpd_settings_dir() { printf '%s/dhcp-scopes' "${LFW_DHCP_SETTINGS_DIR:-/etc/litefwm}"; }
dhcpd_settings_file() { printf '%s/%s.json' "$(dhcpd_settings_dir)" "$1"; }
dhcpd_legacy_read() { # Parse scope files created before 2.2.9.
  local _f
  _f=$(dhcpd_file "$1")
  [ -f "$_f" ] || { echo '{"enabled":false}'; return; }
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
dhcpd_read() {
  local _f _enabled
  _f=$(dhcpd_settings_file "$1")
  _enabled=false; dhcpd_exists "$1" && _enabled=true
  if [ -f "$_f" ]; then
    jq -c --argjson enabled "$_enabled" '. + {enabled:$enabled}' "$_f"
  else
    dhcpd_legacy_read "$1"
  fi
}

dhcpd_all() {
  local _o _f _i _seen
  _o='{}'
  _seen=' '
  for _f in "$LFW_DNSMASQ_DIR"/30-dhcp-*.conf "$(dhcpd_settings_dir)"/*.json; do
    [ -f "$_f" ] || continue
    _i=${_f##*/}
    case "$_i" in
      30-dhcp-*.conf) _i=${_i#30-dhcp-}; _i=${_i%.conf};;
      *.json) _i=${_i%.json};;
    esac
    case "$_seen" in *" $_i "*) continue;; esac
    _seen="$_seen$_i "
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

# dhcpd.set {interface,enabled,start,end,leaseTime,router,dns:[],
#            domain,searchDomains:[],ntp:[],wins:[],bootFile,nextServer}
# OFF means draft-only; explicitly enabling is the ONLY action that emits a
# DHCP range and starts the DHCP service on the chosen LAN interface.
op_dhcpd_set() {
  local _i _enabled _s _e _lt _r _dns _dom _search _ntp _wins _boot _next _c _own _tag
  local _d _t _settings _f _old _tconf
  _i=$(jget interface); need_iface "$_i"
  _enabled=false; jbool enabled && _enabled=true
  jq -e '(.dns // [] | type=="array") and
         (.ntp // [] | type=="array") and
         (.searchDomains // [] | type=="array") and
         (.wins // [] | type=="array")' "$BODY" >/dev/null || die "DNS, NTP, search domains and WINS must be lists"
  _s=$(jget start); _e=$(jget end)
  _lt=$(jget leaseTime); _lt=${_lt:-12h}
  is_lease_time "$_lt" || die "invalid lease time (e.g. 3600, 30m, 12h, 7d)"
  _r=$(jget router); [ -z "$_r" ] || is_ipv4 "$_r" || die "invalid gateway"
  _dns=$(jlist dns | tr '\n' ' ')
  for _d in $_dns; do is_ipv4 "$_d" || die "invalid DNS server $_d"; done
  _dom=$(jget domain); [ -z "$_dom" ] || is_fqdn "$_dom" || die "invalid DHCP domain"
  _search=$(jlist searchDomains | tr '\n' ' ')
  for _d in $_search; do is_fqdn "$_d" || die "invalid domain search suffix $_d"; done
  _ntp=$(jlist ntp | tr '\n' ' ')
  for _d in $_ntp; do is_ipv4 "$_d" || die "invalid NTP server $_d"; done
  _wins=$(jlist wins | tr '\n' ' ')
  for _d in $_wins; do is_ipv4 "$_d" || die "invalid WINS server $_d"; done
  _boot=$(jget bootFile)
  if [ -n "$_boot" ]; then
    printf '%s' "$_boot" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.\/-]{0,127}$' ||
      die "invalid network boot filename"
  fi
  _next=$(jget nextServer); [ -z "$_next" ] || is_ipv4 "$_next" || die "invalid PXE next-server"
  [ -z "$_next" ] || [ -n "$_boot" ] || die "PXE boot filename is required when next-server is set"
  # Preserve configured fields independently of whether the DHCP server runs.
  # Avoid mutating a live scope unless the Enable checkbox was explicitly set.
  if [ "$_enabled" = true ]; then
    [ "$(role_of "$_i")" = lan ] || die "enable DHCP only on a LAN interface"
    dhcp_running "$_i" && die "$_i uses a DHCP client; configure a static LAN address first"
    is_ipv4 "$_s" && is_ipv4 "$_e" || die "range start/end must be IPv4 addresses"
    _c=$(iface_cidr_for "$_i" "$_s") || die "$_s is outside the interface's subnet"
    in_cidr "$_e" "$_c" || die "range start/end are not within the same LAN subnet"
    [ "$(ip2int "$_s")" -le "$(ip2int "$_e")" ] || die "range start must not exceed range end"
    _own=${_c%/*}
    if [ "$(ip2int "$_own")" -ge "$(ip2int "$_s")" ] &&
       [ "$(ip2int "$_own")" -le "$(ip2int "$_e")" ]; then
      die "DHCP range includes the firewall address $_own"
    fi
  else
    # Saving an offline draft allows range fields to be blank until enabled.
    [ -z "$_s" ] || is_ipv4 "$_s" || die "invalid range start"
    [ -z "$_e" ] || is_ipv4 "$_e" || die "invalid range end"
  fi
  _settings=$(dhcpd_settings_file "$_i")
  mkdir -p "$(dhcpd_settings_dir)"
  _t=$(mktemp)
  jq -c --arg lt "$_lt" --arg s "$_s" --arg e "$_e" --arg r "$_r" \
    --arg dom "$_dom" --arg boot "$_boot" --arg next "$_next" '
      {start:$s,end:$e,leaseTime:$lt,router:$r,
       dns:(.dns // []),domain:$dom,searchDomains:(.searchDomains // []),
       ntp:(.ntp // []),wins:(.wins // []),bootFile:$boot,nextServer:$next}' "$BODY" >"$_t"

  if [ "$_enabled" = false ]; then
    _had=false; dhcpd_exists "$_i" && _had=true
    # If the caller omitted all fields, keep legacy active options as a draft.
    if [ "$_had" = true ] &&
       ! jhas start && ! jhas end; then
      dhcpd_legacy_read "$_i" | jq -c 'del(.enabled)' >"$_t"
    fi
    install -m 0644 "$_t" "$_settings"; rm -f "$_t"
    dhcpd_remove "$_i"
    if [ "$_had" = true ]; then fw_sync; dnsmasq_apply; fi
    log_op "dhcpd.set $_i OFF (settings saved; no DHCP server)"
    return 0
  fi
  _tag=$(dhcpd_tag "$_i")
  _tconf=$(mktemp)
  {
    echo "# LiteFWM DHCP server for $_i"
    echo "dhcp-range=set:$_tag,$_s,$_e,$(cidr_mask "${_c#*/}"),$_lt"
    echo "dhcp-option=tag:$_tag,option:router,${_r:-$_own}"
    echo "dhcp-option=tag:$_tag,option:dns-server,$(printf '%s' "${_dns:-$_own}" | sed 's/ *$//; s/ /,/g')"
    [ -z "$_dom" ] || echo "dhcp-option=tag:$_tag,option:domain-name,$_dom"
    [ -z "$_search" ] || echo "dhcp-option=tag:$_tag,option:domain-search,$(printf '%s' "$_search" | sed 's/ *$//; s/ /,/g')"
    [ -z "$_ntp" ] || echo "dhcp-option=tag:$_tag,option:ntp-server,$(printf '%s' "$_ntp" | sed 's/ *$//; s/ /,/g')"
    [ -z "$_wins" ] || echo "dhcp-option=tag:$_tag,option:netbios-ns,$(printf '%s' "$_wins" | sed 's/ *$//; s/ /,/g')"
    [ -z "$_boot" ] || echo "dhcp-boot=tag:$_tag,$_boot,,$([ -n "$_next" ] && echo "$_next" || echo "$_own")"
  } >"$_tconf"
  _f=$(dhcpd_file "$_i"); _old=""
  [ ! -f "$_f" ] || { _old=$(mktemp); cp "$_f" "$_old"; }
  mkdir -p "$LFW_DNSMASQ_DIR"
  install -m 0644 "$_tconf" "$_f"; rm -f "$_tconf"
  if ! dnsmasq_check; then
    if [ -n "$_old" ]; then mv "$_old" "$_f"; else rm -f "$_f"; fi
    rm -f "$_t"
    die "dnsmasq rejected DHCP options: $(dnsmasq_check_msg)"
  fi
  rm -f "$_old"
  install -m 0644 "$_t" "$_settings"; rm -f "$_t"
  fw_sync; dnsmasq_apply
  log_op "dhcpd.set $_i ON $_s-$_e router=${_r:-$_own}"
}

# dhcpd_rename FROM TO: the DHCP server follows the L3 endpoint
dhcpd_rename() {
  local _f _a _b
  _cfg=$(dhcpd_settings_file "$1")
  if [ -f "$_cfg" ]; then
    mkdir -p "$(dhcpd_settings_dir)"
    mv "$_cfg" "$(dhcpd_settings_file "$2")"
  fi
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