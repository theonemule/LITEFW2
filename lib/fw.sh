# shellcheck shell=sh
# Firewall and NAT. The running iptables ruleset is the only copy of the rules.
#
# Every change: snapshot the LiteFWM chains from the kernel, edit the snapshot,
# load the complete ruleset atomically with iptables-restore, then save the
# result with iptables-save for boot (Alpine's iptables service restores it).
#
# Chains
#   filter INPUT   : lo, established, DHCP-client replies, LFW_MGMT, LFW_SVC, LFW_IN, DROP
#   filter FORWARD : established, DNAT'ed (port forwards), LFW_FWD, DROP
#   LFW_MGMT  SSH access configured from System settings
#   LFW_WEB   mandatory LAN-only web guard (never configurable to WAN)
#   LFW_SVC   DNS/DHCP/ping to the firewall from LAN segments (derived from segments)
#   LFW_MOD   derived service openings for installed optional modules
#   LFW_IN    user rules with destination "this firewall"
#   LFW_FWD   user rules between segments / to the internet
#   nat LFW_DNAT  port forwards
#   nat LFW_SNAT  masquerade out of the WAN segment (derived from the WAN role)

FWT=""
fw_snapshot() {
  local _c
  FWT=$(mktemp -d)
  for _c in LFW_IN LFW_FWD LFW_MGMT; do
    iptables -S "$_c" 2>/dev/null | grep '^-A ' >"$FWT/$_c" || true
  done
  iptables -t nat -S LFW_DNAT 2>/dev/null | grep '^-A ' >"$FWT/LFW_DNAT" || true
}
fw_cleanup() { [ -z "$FWT" ] || rm -rf "$FWT"; FWT=""; }

fw_gen_svc() {
  local _i
  for _i in $(lan_ifaces); do
    echo "-A LFW_SVC -i $_i -p udp -m udp --dport 53 -j ACCEPT"
    echo "-A LFW_SVC -i $_i -p tcp -m tcp --dport 53 -j ACCEPT"
    echo "-A LFW_SVC -i $_i -p icmp -m icmp --icmp-type 8 -j ACCEPT"
    if dhcpd_exists "$_i"; then echo "-A LFW_SVC -i $_i -p udp -m udp --dport 67 -j ACCEPT"; fi
  done
}
fw_gen_snat() {
  local _w
  _w=$(wan_iface)
  [ -z "$_w" ] || echo "-A LFW_SNAT -o $_w -j MASQUERADE"
}
# Current management access list: "any" or interface names, read from LFW_MGMT.
mgmt_access_live() {
  if [ ! -s "$FWT/LFW_MGMT" ] || grep -qv -- ' -i ' "$FWT/LFW_MGMT"; then echo any; return; fi
  awk '{for(i=1;i<=NF;i++) if($i=="-i") print $(i+1)}' "$FWT/LFW_MGMT" | sort -u
}
# fw_gen_mgmt ACCESS... (SSH only; management web is LAN-only)
fw_gen_mgmt() {
  local _ssh _sshon _a _if
  _ssh=$(ssh_port); _sshon=false; ssh_enabled && _sshon=true
  for _a in "$@"; do
    _if=""; [ "$_a" = any ] || _if="-i $_a "
    [ "$_sshon" = false ] || echo "-A LFW_MGMT ${_if}-p tcp -m tcp --dport $_ssh -m comment --comment lfw:ssh -j ACCEPT"
  done
}

# The web listener is independently guarded even when a user adds a firewall
# input allow on WAN. Reject attempts before conntrack established/related.
fw_gen_web() {
  local _web _if
  _web=$(mgmt_port)
  for _if in $(lan_ifaces); do
    echo "-A LFW_WEB -i $_if -p tcp -m tcp --dport $_web -j ACCEPT"
  done
  echo "-A LFW_WEB -p tcp -m tcp --dport $_web -j DROP"
}

# fw_commit [MGMT_ACCESS...]: assemble and load the full ruleset from $FWT.
fw_commit() {
  local _c _r _e
  if [ $# -gt 0 ]; then fw_gen_mgmt "$@" >"$FWT/LFW_MGMT"
  else
    # shellcheck disable=SC2046
    fw_gen_mgmt $(mgmt_access_live) >"$FWT/LFW_MGMT.new"; mv "$FWT/LFW_MGMT.new" "$FWT/LFW_MGMT"
  fi
  _r=$FWT/ruleset
  {
    echo '*raw'
    echo ':PREROUTING ACCEPT [0:0]'
    echo ':OUTPUT ACCEPT [0:0]'
    echo 'COMMIT'
    echo '*mangle'
    for _c in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do echo ":$_c ACCEPT [0:0]"; done
    echo 'COMMIT'
    echo '*nat'
    for _c in PREROUTING INPUT OUTPUT POSTROUTING; do echo ":$_c ACCEPT [0:0]"; done
    echo ':LFW_DNAT - [0:0]'
    echo ':LFW_SNAT - [0:0]'
    echo '-A PREROUTING -j LFW_DNAT'
    echo '-A POSTROUTING -j LFW_SNAT'
    cat "$FWT/LFW_DNAT"
    fw_gen_snat
    echo 'COMMIT'
    echo '*filter'
    echo ':INPUT DROP [0:0]'
    echo ':FORWARD DROP [0:0]'
    echo ':OUTPUT ACCEPT [0:0]'
    for _c in LFW_WEB LFW_MGMT LFW_SVC LFW_MOD LFW_IN LFW_FWD; do echo ":$_c - [0:0]"; done
    echo "-A INPUT -p tcp -m tcp --dport $(mgmt_port) -j LFW_WEB"
    echo '-A INPUT -i lo -j ACCEPT'
    echo '-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
    echo '-A INPUT -m conntrack --ctstate INVALID -j DROP'
    echo '-A INPUT -p udp -m udp --sport 67 --dport 68 -j ACCEPT'
    echo '-A INPUT -j LFW_MGMT'
    echo '-A INPUT -j LFW_SVC'
    echo '-A INPUT -j LFW_MOD'
    echo '-A INPUT -j LFW_IN'
    echo '-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
    echo '-A FORWARD -m conntrack --ctstate INVALID -j DROP'
    echo '-A FORWARD -m conntrack --ctstate DNAT -j ACCEPT'
    echo '-A FORWARD -j LFW_FWD'
    fw_gen_web
    cat "$FWT/LFW_MGMT"
    fw_gen_svc
    if command -v module_firewall_rules >/dev/null 2>&1; then module_firewall_rules; fi
    cat "$FWT/LFW_IN"
    cat "$FWT/LFW_FWD"
    echo 'COMMIT'
  } >"$_r"
  if ! _e=$(iptables-restore <"$_r" 2>&1); then
    fw_cleanup; die "firewall rejected the change: $_e"
  fi
  mkdir -p "$(dirname "$LFW_FW_SAVE")"
  iptables-save >"$LFW_FW_SAVE.tmp" && mv "$LFW_FW_SAVE.tmp" "$LFW_FW_SAVE"
  fw_cleanup
}

# Re-derive LFW_SVC / LFW_SNAT / LFW_MGMT from current live state.
fw_sync() { fw_snapshot; fw_commit; }

fw_rename_iface() { # FROM TO
  local _f
  fw_snapshot
  for _f in LFW_IN LFW_FWD LFW_DNAT LFW_MGMT; do
    awk -v a="$1" -v b="$2" '{for(i=1;i<NF;i++) if(($i=="-i"||$i=="-o") && $(i+1)==a) $(i+1)=b; print}' \
      "$FWT/$_f" >"$FWT/$_f.n" && mv "$FWT/$_f.n" "$FWT/$_f"
  done
  if [ "$(mgmt_access_live)" = any ]; then fw_commit any; else
    # shellcheck disable=SC2046
    fw_commit $(mgmt_access_live)
  fi
}

# fw_refs IFACE: true if a user rule or port forward references IFACE.
fw_refs() {
  { iptables -S LFW_FWD; iptables -S LFW_IN; iptables -t nat -S LFW_DNAT; } 2>/dev/null |
    awk -v a="$1" '{for(i=1;i<NF;i++) if(($i=="-i"||$i=="-o") && $(i+1)==a) f=1} END{exit !f}'
}

fw_ensure() {
  iptables -S INPUT 2>/dev/null | grep -q -- '-j LFW_MGMT' && return 0
  fw_snapshot; fw_commit any
}

fw_parse() { awk -f "$LFW_LIB/fwparse.awk"; }

fw_state() {
  local _in _fwd _dnat _snat _pol
  _in=$(iptables -S LFW_IN 2>/dev/null | fw_parse | jq -s .)
  _fwd=$(iptables -S LFW_FWD 2>/dev/null | fw_parse | jq -s .)
  _dnat=$(iptables -t nat -S LFW_DNAT 2>/dev/null | fw_parse | jq -s .)
  _snat=$(iptables -t nat -S LFW_SNAT 2>/dev/null | fw_parse | jq -s .)
  _pol=$(iptables -S 2>/dev/null | awk '$1=="-P"{printf "\"%s\":\"%s\",", $2, $3}')
  jq -n --argjson in "${_in:-[]}" --argjson fwd "${_fwd:-[]}" --argjson dnat "${_dnat:-[]}" \
        --argjson snat "${_snat:-[]}" --argjson pol "{${_pol%,}}" '
    def rule($chain): {
      id, chain: $chain, description,
      action: (.target | ascii_downcase),
      in, out, src, dst,
      proto: (if .proto == "" then "any" else .proto end),
      ports, managed, raw };
    {
      policies: $pol,
      rules: ([ $fwd[] | rule("forward") ] + [ $in[] | rule("input") ]),
      forwards: ( $dnat | group_by(.id) | map(
          .[0] as $r | ($r.toDestination | split(":")) as $td |
          { id: $r.id, description: $r.description, in: $r.in, src: $r.src,
            proto: (if length > 1 then "both" else $r.proto end),
            port: $r.ports, to: $td[0], toPort: (($td[1] // "") | gsub(":"; "-")),
            managed: $r.managed, raw: ([.[].raw] | join("\n")) } )),
      masquerade: [ $snat[] | .out ]
    }'
}

# ---------------------------------------------------------------- rule building
new_id() { od -An -N4 -tx1 /dev/urandom | tr -d ' \n'; }

need_fw_iface() { # IFACE (may be empty)
  local _m
  [ -z "$1" ] && return 0
  is_ifname "$1" || die "invalid interface $1"
  iface_exists "$1" || die "interface $1 does not exist"
  _m=$(iface_master "$1"); [ -z "$_m" ] || die "$1 is a bridge port; use $_m"
}

# fw_rule_line CHAIN ID : build a user rule from $BODY
fw_rule_line() {
  _ch=$1 _id=$2
  _act=$(jget action); _act=$(lower "${_act:-accept}")
  case "$_act" in accept) _t=ACCEPT;; drop) _t=DROP;; reject) _t=REJECT;; *) die "action must be accept, drop or reject";; esac
  _in=$(jget in); _out=$(jget out); _src=$(jget src); _dst=$(jget dst)
  _p=$(jget proto); _p=$(lower "${_p:-any}"); _ports=$(jget ports); _d=$(jget description)
  need_fw_iface "$_in"; need_fw_iface "$_out"
  [ "$_ch" = LFW_FWD ] || [ -z "$_out" ] || die "rules to the firewall itself have no output interface"
  [ -z "$_src" ] || is_addr "$_src" || die "invalid source address $_src"
  [ -z "$_dst" ] || is_addr "$_dst" || die "invalid destination address $_dst"
  is_desc "$_d" || die "description may use letters, digits, space and _ . , : / ( ) + # @ - (max 64)"
  _l="-A $_ch"
  [ -z "$_in" ] || _l="$_l -i $_in"
  [ -z "$_out" ] || _l="$_l -o $_out"
  [ -z "$_src" ] || _l="$_l -s $_src"
  [ -z "$_dst" ] || _l="$_l -d $_dst"
  case "$_p" in
    any) [ -z "$_ports" ] || die "ports need protocol tcp or udp";;
    icmp) [ -z "$_ports" ] || die "ports need protocol tcp or udp"; _l="$_l -p icmp";;
    tcp|udp)
      _l="$_l -p $_p"
      if [ -n "$_ports" ]; then
        is_ports "$_ports" || die "invalid ports '$_ports' (e.g. 443, 8000-8100, 80,443)"
        _pp=$(printf '%s' "$_ports" | tr '-' ':')
        case "$_ports" in
          *,*) _l="$_l -m multiport --dports $_pp";;
          *) _l="$_l -m $_p --dport $_pp";;
        esac
      fi;;
    *) die "protocol must be any, tcp, udp or icmp";;
  esac
  _c="lfw:$_id"; [ -z "$_d" ] || _c="$_c $_d"
  printf '%s -m comment --comment "%s" -j %s\n' "$_l" "$_c" "$_t"
}

# file helpers: find/remove/insert lines by rule id
fw_has_id() { grep -Eq -- "--comment \"?lfw:$2( |\"|\$)" "$1"; }
fw_chain_of() { local _f; for _f in LFW_FWD LFW_IN; do fw_has_id "$FWT/$_f" "$1" && { echo "$_f"; return 0; }; done; return 1; }
fw_index_of() { grep -En -- "--comment \"?lfw:$2( |\"|\$)" "$1" | head -n 1 | cut -d: -f1; }
fw_remove_id() { grep -Ev -- "--comment \"?lfw:$2( |\"|\$)" "$1" >"$1.n" || true; mv "$1.n" "$1"; }
# fw_insert FILE POS(0-based, empty=end) LINE
fw_insert() {
  printf '%s\n' "$3" >"$FWT/ins"
  if [ -z "$2" ]; then cat "$FWT/ins" >>"$1"; return; fi
  awk -v n="$2" -v f="$FWT/ins" 'NR==n+1{while((getline x < f)>0) print x; done=1} {print} END{if(!done) while((getline x < f)>0) print x}' "$1" >"$1.n"
  mv "$1.n" "$1"
}
chain_for() {
  case "$(lower "${1:-forward}")" in forward) echo LFW_FWD;; input) echo LFW_IN;; *) die "chain must be forward or input";; esac
}
valid_pos() { [ -z "$1" ] || is_uint "$1" || die "invalid position"; }
valid_id() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}$' || die "invalid rule id"; }

op_rule_add() {
  _ch=$(chain_for "$(jget chain)"); _pos=$(jget position); valid_pos "$_pos"
  fw_snapshot
  _id=$(new_id)
  _line=$(fw_rule_line "$_ch" "$_id") || { fw_cleanup; exit 1; }
  fw_insert "$FWT/$_ch" "$_pos" "$_line"
  fw_commit
  log_op "rule.add $_id $_line"
  printf '{"id":"%s"}' "$_id" >"$RESULT"
}

op_rule_update() {
  _id=$(jget id); valid_id "$_id"
  fw_snapshot
  _old=$(fw_chain_of "$_id") || { fw_cleanup; die "rule $_id not found"; }
  _ch=$(chain_for "$(jget chain)")
  _line=$(fw_rule_line "$_ch" "$_id") || { fw_cleanup; exit 1; }
  if [ "$_old" = "$_ch" ]; then
    _n=$(fw_index_of "$FWT/$_ch" "$_id")
    fw_remove_id "$FWT/$_ch" "$_id"
    fw_insert "$FWT/$_ch" "$((_n - 1))" "$_line"
  else
    fw_remove_id "$FWT/$_old" "$_id"
    fw_insert "$FWT/$_ch" "" "$_line"
  fi
  fw_commit
  log_op "rule.update $_id $_line"
}

op_rule_delete() {
  _id=$(jget id); valid_id "$_id"
  fw_snapshot
  _ch=$(fw_chain_of "$_id") || { fw_cleanup; die "rule $_id not found"; }
  fw_remove_id "$FWT/$_ch" "$_id"
  fw_commit
  log_op "rule.delete $_id"
}

op_rule_move() {
  _id=$(jget id); valid_id "$_id"; _pos=$(jget position); is_uint "$_pos" || die "position required"
  fw_snapshot
  _ch=$(fw_chain_of "$_id") || { fw_cleanup; die "rule $_id not found"; }
  _n=$(fw_index_of "$FWT/$_ch" "$_id")
  _line=$(sed -n "${_n}p" "$FWT/$_ch")
  fw_remove_id "$FWT/$_ch" "$_id"
  fw_insert "$FWT/$_ch" "$_pos" "$_line"
  fw_commit
  log_op "rule.move $_id -> $_pos"
}

# ---------------------------------------------------------------- port forwards
# forward.add {in (default WAN), src, proto: tcp|udp|both, port, to, toPort, description}
fw_forward_lines() {
  _id=$1
  _in=$(jget in); [ -n "$_in" ] || _in=$(wan_iface)
  [ -n "$_in" ] || die "no WAN segment is defined; set one before adding port forwards"
  need_fw_iface "$_in"
  _src=$(jget src); [ -z "$_src" ] || is_addr "$_src" || die "invalid source restriction $_src"
  _p=$(lower "$(jget proto)"); _p=${_p:-tcp}
  _port=$(jget port); _to=$(jget to); _tp=$(jget toPort); _d=$(jget description)
  case "$_port" in *,*) die "use a single port or a range";; esac
  is_ports "$_port" || die "invalid external port"
  is_ipv4 "$_to" || die "invalid internal IP address"
  if [ -n "$_tp" ]; then
    is_port "$_tp" || die "internal port must be a single port"
    case "$_port" in *-*) die "a port range forwards to the same ports; leave internal port empty";; esac
  fi
  is_desc "$_d" || die "invalid description"
  case "$_p" in tcp) _ps=tcp;; udp) _ps=udp;; both) _ps="tcp udp";; *) die "protocol must be tcp, udp or both";; esac
  _c="lfw:$_id"; [ -z "$_d" ] || _c="$_c $_d"
  _dest=$_to; [ -z "$_tp" ] || _dest="$_to:$_tp"
  _pp=$(printf '%s' "$_port" | tr '-' ':')
  for _x in $_ps; do
    _l="-A LFW_DNAT -i $_in"
    [ -z "$_src" ] || _l="$_l -s $_src"
    printf '%s -p %s -m %s --dport %s -m comment --comment "%s" -j DNAT --to-destination %s\n' "$_l" "$_x" "$_x" "$_pp" "$_c" "$_dest"
  done
}

op_forward_add() {
  fw_snapshot
  _id=$(new_id)
  _lines=$(fw_forward_lines "$_id") || { fw_cleanup; exit 1; }
  printf '%s\n' "$_lines" >>"$FWT/LFW_DNAT"
  fw_commit
  log_op "forward.add $_id $(printf '%s' "$_lines" | tr '\n' ' ')"
  printf '{"id":"%s"}' "$_id" >"$RESULT"
}

op_forward_update() {
  _id=$(jget id); valid_id "$_id"
  fw_snapshot
  fw_has_id "$FWT/LFW_DNAT" "$_id" || { fw_cleanup; die "port forward $_id not found"; }
  _lines=$(fw_forward_lines "$_id") || { fw_cleanup; exit 1; }
  _n=$(fw_index_of "$FWT/LFW_DNAT" "$_id")
  fw_remove_id "$FWT/LFW_DNAT" "$_id"
  fw_insert "$FWT/LFW_DNAT" "$((_n - 1))" "$_lines"
  fw_commit
  log_op "forward.update $_id"
}

op_forward_delete() {
  _id=$(jget id); valid_id "$_id"
  fw_snapshot
  fw_has_id "$FWT/LFW_DNAT" "$_id" || { fw_cleanup; die "port forward $_id not found"; }
  fw_remove_id "$FWT/LFW_DNAT" "$_id"
  fw_commit
  log_op "forward.delete $_id"
}