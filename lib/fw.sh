# shellcheck shell=sh
# nftables-backend: LiteFW owns only table inet litefw.
# All firewall/NAT transactions are syntax-checked and applied atomically.
# iproute2 separately owns routes and interfaces; other nft tables are untouched.

FWT=""
fw_read_chain() {
  nft -a list chain inet litefw "$1" 2>/dev/null |
    awk '/# handle [0-9]+/ && $0 !~ /chain / {
      sub(/^[[:space:]]+/, ""); sub(/[[:space:]]*# handle [0-9]+.*$/, "");
      if (length($0)) print
    }'
}
fw_snapshot() {
  local _c
  FWT=$(mktemp -d)
  for _c in LFW_IN LFW_FWD LFW_OUT LFW_ORDER LFW_MGMT LFW_DNAT; do
    fw_read_chain "$_c" >"$FWT/$_c"
  done
}
fw_cleanup() { [ -z "$FWT" ] || rm -rf "$FWT"; FWT=""; }

fw_gen_svc() {
  local _i
  for _i in $(lan_ifaces); do
    printf 'iifname "%s" udp dport 53 accept\n' "$_i"
    printf 'iifname "%s" tcp dport 53 accept\n' "$_i"
    printf 'iifname "%s" meta l4proto icmp icmp type echo-request accept\n' "$_i"
    if dhcpd_exists "$_i"; then printf 'iifname "%s" udp dport 67 accept\n' "$_i"; fi
  done
}
fw_gen_snat() {
  local _w
  _w=$(wan_iface)
  [ -z "$_w" ] || printf 'oifname "%s" masquerade\n' "$_w"
  if command -v module_firewall_snat_rules >/dev/null 2>&1; then
    module_firewall_snat_rules "$_w"
  fi
}
mgmt_access_live() {
  if [ ! -s "$FWT/LFW_MGMT" ] || grep -qv 'iifname ' "$FWT/LFW_MGMT"; then echo any; return; fi
  sed -n 's/.*iifname "\([^"]*\)".*/\1/p' "$FWT/LFW_MGMT" | sort -u
}
fw_gen_mgmt() {
  local _ssh _sshon _a _if
  _ssh=$(ssh_port); _sshon=false; ssh_enabled && _sshon=true
  for _a in "$@"; do
    _if=""; [ "$_a" = any ] || _if="iifname \"$_a\" "
    [ "$_sshon" = false ] || printf '%stcp dport %s accept comment "lfw:ssh"\n' "$_if" "$_ssh"
  done
}
# First dispatch for management web port MUST precede conntrack accept.
fw_gen_web() {
  local _web _if
  _web=$(mgmt_port)
  for _if in $(lan_ifaces); do
    printf 'iifname "%s" tcp dport %s accept\n' "$_if" "$_web"
  done
  printf 'tcp dport %s drop\n' "$_web"
}

# Translate module-generated legacy rule *descriptors* to nft syntax.
# No iptables executable is called. Reject unknown grammar rather than
# silently omitting security rules.
fw_module_translate() {
  awk '
    function fail() { print "Unsupported module firewall rule: " $0 >"/dev/stderr"; exit 1 }
    /^-A / {
      chain=$2; if(chain!="LFW_MOD" && chain!="LFW_FWD") fail()
      expr=""; proto=""; action=""; comment=""
      for(i=3;i<=NF;i++){
        t=$i
        if(t=="-i") expr=expr "iifname \"" $(++i) "\" "
        else if(t=="-o") expr=expr "oifname \"" $(++i) "\" "
        else if(t=="-s") expr=expr "ip saddr " $(++i) " "
        else if(t=="-d") expr=expr "ip daddr " $(++i) " "
        else if(t=="-p") {proto=$(++i); if(proto=="esp") expr=expr "meta l4proto esp " }
        else if(t=="-m") { i++; }
        else if(t=="--dport") { port=$(++i); if(proto=="") fail(); expr=expr proto " dport " port " " }
        else if(t=="--dports") { ports=$(++i); gsub(/,/ , ", ", ports); expr=expr proto " dport { " ports " } " }
        else if(t=="--match-set") { set=$(++i); dir=$(++i); if(dir!="src") fail(); expr=expr "ip saddr @" set " " }
        else if(t=="--comment") { comment=$(++i) }
        else if(t=="-j") {action=tolower($(++i))}
        else fail()
      }
      if(action!="accept" && action!="drop" && action!="reject") fail()
      if(proto!="" && proto!="esp" && expr !~ / dport /) expr=expr "meta l4proto " proto " "
      print chain "|" expr action (comment!="" ? " comment \"" comment "\"" : "")
      next
    }
    NF {fail()}
  '
}
fw_module_dump() {
  if command -v module_firewall_rules >/dev/null 2>&1; then
    module_firewall_rules | fw_module_translate
  fi
}
# Display/order metadata is a non-hooked nftables chain; packet policy
# remains in the appropriate INPUT, FORWARD, or OUTPUT hook.
fw_order_reconcile() {
  local _n1 _n2 _n3 _valid _file _n _idx
  _n1=$(wc -l <"$FWT/LFW_FWD"); _n2=$(wc -l <"$FWT/LFW_IN"); _n3=$(wc -l <"$FWT/LFW_OUT")
  _valid=no
  if [ -f "$FWT/LFW_ORDER" ]; then
    if awk -v f="$_n1" -v i="$_n2" -v o="$_n3" '
      /lfw-order:/ {
        x=$0; sub(/^.*lfw-order:/,"",x); sub(/".*$/,"",x);
        split(x,a,":"); key=a[1] ":" a[2]; n=a[2]
        if(a[1]=="LFW_FWD" && n+0<f && n~/^[0-9]+$/) {}
        else if(a[1]=="LFW_IN" && n+0<i && n~/^[0-9]+$/) {}
        else if(a[1]=="LFW_OUT" && n+0<o && n~/^[0-9]+$/) {}
        else bad=1
        if(seen[key]++) bad=1
        matched++
      }
      END{exit !(matched==f+i+o && !bad)}
    ' "$FWT/LFW_ORDER"; then _valid=yes; fi
  fi
  [ "$_valid" != yes ] || return 0
  : >"$FWT/LFW_ORDER"
  for _file in LFW_FWD LFW_IN LFW_OUT; do
    _n=$(wc -l <"$FWT/$_file")
    _idx=0
    while [ "$_idx" -lt "$_n" ]; do
      printf 'counter comment "lfw-order:%s:%s"\n' "$_file" "$_idx" >>"$FWT/LFW_ORDER"
      _idx=$((_idx + 1))
    done
  done
}
fw_indent_file() { [ ! -f "$1" ] || sed '/^[[:space:]]*$/d;s/^/    /' "$1"; }
fw_commit() {
  local _c _r _e _old _add
  if [ $# -gt 0 ]; then
    fw_gen_mgmt "$@" >"$FWT/LFW_MGMT"
  else
    # shellcheck disable=SC2046
    fw_gen_mgmt $(mgmt_access_live) >"$FWT/LFW_MGMT.new"
    mv "$FWT/LFW_MGMT.new" "$FWT/LFW_MGMT"
  fi
  # Keep derived rules in the right chain, regardless of the module order.
  fw_module_dump >"$FWT/modules" || { fw_cleanup; die 'Cannot translate module firewall rules'; }
  sed -n 's/^LFW_MOD|//p' "$FWT/modules" >"$FWT/LFW_MOD"
  sed -n 's/^LFW_FWD|//p' "$FWT/modules" >"$FWT/LFW_DERIVED"
  fw_gen_snat >"$FWT/LFW_SNAT"
  fw_gen_svc >"$FWT/LFW_SVC"
  fw_gen_web >"$FWT/LFW_WEB"
  fw_order_reconcile
  _r="$FWT/ruleset"
  {
    # destroy is idempotent, even when the owned table does not yet exist.
    echo 'destroy table inet litefw'
    echo 'table inet litefw {'
    # Existing native GeoIP set is separately persisted by the geoip module.
    if grep -q '@litefw_geo4' "$FWT/modules"; then
      # Production uses /etc/litefw-addons; isolated tests can use an
      # alternate module configuration root without changing /etc.
      _geo_file="${LFW_MODULE_CONFIG_DIR:-/etc/litefw-addons}/geoip.nft"
      [ -s "$_geo_file" ] || { fw_cleanup; die 'GeoIP is enabled but no nftables feed is loaded'; }
      cat "$_geo_file"
    fi
    for _c in LFW_WEB LFW_MGMT LFW_SVC LFW_MOD LFW_IN LFW_FWD LFW_OUT LFW_ORDER; do
      printf '  chain %s {\n' "$_c"
      case "$_c" in
        LFW_WEB) fw_indent_file "$FWT/LFW_WEB";;
        LFW_MGMT) fw_indent_file "$FWT/LFW_MGMT";;
        LFW_SVC) fw_indent_file "$FWT/LFW_SVC";;
        LFW_MOD) fw_indent_file "$FWT/LFW_MOD";;
        LFW_IN) fw_indent_file "$FWT/LFW_IN";;
        LFW_FWD) fw_indent_file "$FWT/LFW_DERIVED"; fw_indent_file "$FWT/LFW_FWD";;
        LFW_OUT) fw_indent_file "$FWT/LFW_OUT";;
        LFW_ORDER) fw_indent_file "$FWT/LFW_ORDER";;
      esac
      echo '  }'
    done
    echo '  chain INPUT {'
    echo '    type filter hook input priority filter; policy drop;'
    printf '    tcp dport %s jump LFW_WEB\n' "$(mgmt_port)"
    echo '    iifname "lo" accept'
    echo '    ct state { established, related } accept'
    echo '    ct state invalid drop'
    echo '    udp sport 67 udp dport 68 accept'
    # User rules can explicitly restrict built-in services other than the
    # protected LAN-only management web port and established replies.
    echo '    jump LFW_IN'
    echo '    jump LFW_MGMT'
    echo '    jump LFW_SVC'
    echo '    jump LFW_MOD'
    echo '  }'
    echo '  chain FORWARD {'
    echo '    type filter hook forward priority filter; policy drop;'
    echo '    ct state { established, related } accept'
    echo '    ct state invalid drop'
    # Explicit policy blocks take precedence over automatic DNAT forwarding.
    echo '    jump LFW_FWD'
    echo '    ct status dnat accept'
    echo '  }'
    echo '  chain OUTPUT {'
    echo '    type filter hook output priority filter; policy accept;'
    echo '    ct state { established, related } accept'
    echo '    jump LFW_OUT'
    echo '  }'
    echo '  chain LFW_DNAT {'
    fw_indent_file "$FWT/LFW_DNAT"
    echo '  }'
    echo '  chain PREROUTING {'
    echo '    type nat hook prerouting priority dstnat; policy accept;'
    echo '    jump LFW_DNAT'
    echo '  }'
    echo '  chain LFW_SNAT {'
    fw_indent_file "$FWT/LFW_SNAT"
    echo '  }'
    echo '  chain POSTROUTING {'
    echo '    type nat hook postrouting priority srcnat; policy accept;'
    # An IPsec protected packet must never be subjected to WAN masquerading.
    if command -v swanctl >/dev/null 2>&1 &&
       rc-service charon status >/dev/null 2>&1; then
      echo '    ipsec out reqid != 0 accept'
    fi
    echo '    jump LFW_SNAT'
    echo '  }'
    echo '}'
  } >"$_r"
  if ! _e=$(nft -c -f "$_r" 2>&1); then
    fw_cleanup; die "nftables rejected the change: $_e"
  fi
  if ! _e=$(nft -f "$_r" 2>&1); then
    fw_cleanup; die "nftables apply failed: $_e"
  fi
  mkdir -p "$(dirname "$LFW_FW_SAVE")"
  { echo 'destroy table inet litefw'; nft list table inet litefw; } >"$LFW_FW_SAVE.tmp" &&
    mv "$LFW_FW_SAVE.tmp" "$LFW_FW_SAVE" ||
    { fw_cleanup; die 'Unable to persist nftables rules'; }
  fw_cleanup
}
fw_sync() { fw_snapshot; fw_commit; }
fw_rename_iface() {
  local _f
  fw_snapshot
  for _f in LFW_IN LFW_FWD LFW_OUT LFW_DNAT LFW_MGMT; do
    sed "s/iifname \"$1\"/iifname \"$2\"/g;s/oifname \"$1\"/oifname \"$2\"/g" "$FWT/$_f" >"$FWT/$_f.n"
    mv "$FWT/$_f.n" "$FWT/$_f"
  done
  # shellcheck disable=SC2046
  fw_commit $(mgmt_access_live)
}
fw_refs() {
  fw_snapshot
  if grep -Fq "iifname \"$1\"" "$FWT/LFW_IN" "$FWT/LFW_FWD" "$FWT/LFW_OUT" "$FWT/LFW_DNAT" ||
     grep -Fq "oifname \"$1\"" "$FWT/LFW_IN" "$FWT/LFW_FWD" "$FWT/LFW_OUT" "$FWT/LFW_DNAT"; then
    fw_cleanup; return 0
  fi
  fw_cleanup; return 1
}
fw_ensure() {
  _input=$(nft list chain inet litefw INPUT 2>/dev/null) || _input=""
  printf '%s' "$_input" | grep -q 'jump LFW_WEB' &&
  printf '%s' "$_input" | grep -q 'jump LFW_MGMT' && return 0
  fw_snapshot; fw_commit any
}
fw_parse() { awk -f "$LFW_LIB/fwparse.awk"; }
fw_live_policy() {
  nft -j list chain inet litefw "$1" 2>/dev/null |
    jq -r --arg n "$1" '[.nftables[].chain? | select(.name==$n) | .policy] | .[0] // empty | ascii_upcase'
}
fw_state() {
  local _in _fwd _out _dnat _snat _pin _pfwd _pout _wan _order
  _pin=$(fw_live_policy INPUT); _pfwd=$(fw_live_policy FORWARD); _pout=$(fw_live_policy OUTPUT)
  _wan=$(wan_iface)
  _in=$(fw_read_chain LFW_IN | fw_parse | jq -s .)
  _fwd=$(fw_read_chain LFW_FWD | fw_parse | jq -s .)
  _out=$(fw_read_chain LFW_OUT | fw_parse | jq -s .)
  _dnat=$(fw_read_chain LFW_DNAT | fw_parse | jq -s .)
  _snat=$(fw_read_chain LFW_SNAT | fw_parse | jq -s .)
  _order=$(fw_read_chain LFW_ORDER | sed -n 's/.*lfw-order:\(LFW_[A-Z]*:[0-9]*\)".*/\1/p' | jq -R -s 'split("\n") | map(select(length>0))')
  jq -n --argjson in "$_in" --argjson fwd "$_fwd" --argjson out "$_out" \
        --argjson dnat "$_dnat" --argjson snat "$_snat" \
        --argjson order "$_order" --arg wan "$_wan" \
        --arg pin "$_pin" --arg pfwd "$_pfwd" --arg pout "$_pout" '
    def rule($chain): {
      id, chain:$chain, description,
      action: (.target | ascii_downcase), in, out, src, dst, srcPorts, ports, managed, raw,
      proto: (if .proto == "" then "any" else .proto end),
      source: {scope:(if $chain=="output" then "host" elif .in!="" and .in==$wan then "wan"
                      elif .in!="" then "interface" else "any" end),
               interface:(if $chain=="output" or .in==$wan then "" else .in end),
               address:.src, ports:.srcPorts},
      destination: {scope:(if $chain=="input" then "host" elif .out!="" and .out==$wan then "wan"
                           elif .out!="" then "interface" else "any" end),
                    interface:(if $chain=="input" or .out==$wan then "" else .out end),
                    address:.dst, ports:.ports} };
    ([$fwd | to_entries[] | {__key:("LFW_FWD:"+(.key|tostring)), __fallback:.key} + .value] +
     [$in | to_entries[] | {__key:("LFW_IN:"+(.key|tostring)), __fallback:(1000+.key)} + .value] +
     [$out | to_entries[] | {__key:("LFW_OUT:"+(.key|tostring)), __fallback:(2000+.key)} + .value]) as $entries |
    {
      policies: {INPUT:$pin,FORWARD:$pfwd,OUTPUT:$pout},
      rules: ($entries | sort_by(.__key as $k | .__fallback as $f | ($order | index($k)) // (100000+$f))
              | map(rule(if .__key|startswith("LFW_IN:") then "input" elif .__key|startswith("LFW_OUT:") then "output" else "forward" end))),
      forwards: ( $dnat | group_by(.id) | map(
        .[0] as $r | ($r.toDestination | split(":")) as $td |
        { id: $r.id, description: $r.description, in: $r.in, src: $r.src,
          proto: (if length > 1 then "both" else $r.proto end),
          port: $r.ports, to: $td[0], toPort: ($td[1] // ""),
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

# Both the web UI and modern API specify endpoints in plain language. This
# determines the correct kernel hook without exposing INPUT/FORWARD/OUTPUT.
fw_rule_chain() {
  local _src_scope _dst_scope
  if jq -e '(.source | type) == "object" and (.destination | type) == "object"' "$BODY" >/dev/null 2>&1; then
    _src_scope=$(jq -r '.source.scope // "any"' "$BODY")
    _dst_scope=$(jq -r '.destination.scope // "any"' "$BODY")
    case "$_src_scope:$_dst_scope" in
      host:host) die 'Traffic originating and ending on the firewall is internal loopback; this rule is not supported';;
      *:host) echo LFW_IN;;
      host:*) echo LFW_OUT;;
      *) echo LFW_FWD;;
    esac
  else
    chain_for "$(jget chain)"
  fi
}

fw_nft_addr_expr() {
  local _value _field
  _value=$1; _field=$2
  [ -n "$_value" ] || return 0
  is_addr_match "$_value" || die "invalid IPv4 address, CIDR, range or list: $_value"
  case "$_value" in
    *,*) printf '%s { %s } ' "$_field" "$(printf '%s' "$_value" | sed 's/,/, /g')";;
    *) printf '%s %s ' "$_field" "$_value";;
  esac
}
fw_nft_port_expr() {
  local _proto _direction _value
  _proto=$1; _direction=$2; _value=$3
  [ -n "$_value" ] || return 0
  is_ports "$_value" || die "Invalid $_direction ports: $_value"
  case "$_value" in
    *,*) printf '%s %s { %s } ' "$_proto" "$_direction" "$(printf '%s' "$_value" | sed 's/,/, /g')";;
    *) printf '%s %s %s ' "$_proto" "$_direction" "$_value";;
  esac
}

# Build one owned native nftables rule, never accept arbitrary nft syntax.
# Structured endpoints:
# source|destination: {scope: any|host|wan|interface, interface, address, ports}
# IPv4 matches support individual addresses, CIDRs, inclusive ranges and lists.
# Legacy {chain,in,out,src,dst,srcPorts,ports} remains supported.
fw_rule_line() {
  local _ch _id _act _in _out _src _dst _sp _dp _p _d _c _l
  _ch=$1; _id=$2
  _act=$(lower "$(jget action)")
  case "$_act" in ''|allow|accept) _act=accept;;
    block|drop) _act=drop;; reject) :;; *) die 'action must be allow, block or reject';; esac
  _p=$(lower "$(jget proto)"); [ -n "$_p" ] || _p=any
  _d=$(jget description)
  if jq -e '(.source | type) == "object" and (.destination | type) == "object"' "$BODY" >/dev/null 2>&1; then
    [ "$_ch" = "$(fw_rule_chain)" ] || die 'Source and destination do not match the inferred packet direction'
    _ss=$(jq -r '.source.scope // "any"' "$BODY")
    _ds=$(jq -r '.destination.scope // "any"' "$BODY")
    _in=""; _out=""
    case "$_ss" in
      host|any) :;;
      wan) _in=$(wan_iface); [ -n "$_in" ] || die 'No WAN interface is assigned';;
      interface) _in=$(jq -r '.source.interface // ""' "$BODY"); [ -n "$_in" ] || die 'Select a source interface';;
      *) die 'Invalid source scope';;
    esac
    case "$_ds" in
      host|any) :;;
      wan) _out=$(wan_iface); [ -n "$_out" ] || die 'No WAN interface is assigned';;
      interface) _out=$(jq -r '.destination.interface // ""' "$BODY"); [ -n "$_out" ] || die 'Select a destination interface';;
      *) die 'Invalid destination scope';;
    esac
    _src=$(jq -r '.source.address // ""' "$BODY")
    _dst=$(jq -r '.destination.address // ""' "$BODY")
    _sp=$(jq -r '.source.ports // ""' "$BODY")
    _dp=$(jq -r '.destination.ports // ""' "$BODY")
  else
    _in=$(jget in); _out=$(jget out)
    _src=$(jget src); _dst=$(jget dst)
    _sp=$(jget srcPorts); _dp=$(jget ports)
  fi
  need_fw_iface "$_in"; need_fw_iface "$_out"
  [ "$_ch" != LFW_IN ] || [ -z "$_out" ] || die 'A rule to this firewall cannot have an outgoing interface'
  [ "$_ch" != LFW_OUT ] || [ -z "$_in" ] || die 'Traffic from this firewall cannot have an incoming interface'
  is_desc "$_d" || die 'Description contains unsupported characters or is too long'
  # Validate in the parent, not in a subshell: invalid source restrictions
  # must never broaden to an unqualified permit if substitution fails.
  [ -z "$_src" ] || is_addr_match "$_src" || die 'Invalid source IP/network/range'
  [ -z "$_dst" ] || is_addr_match "$_dst" || die 'Invalid destination IP/network/range'
  [ -z "$_sp" ] || is_ports "$_sp" || die 'Invalid source ports'
  [ -z "$_dp" ] || is_ports "$_dp" || die 'Invalid destination ports'
  _l=""
  [ -z "$_in" ] || _l="$_l iifname \"$_in\""
  [ -z "$_out" ] || _l="$_l oifname \"$_out\""
  _l="$_l $(fw_nft_addr_expr "$_src" 'ip saddr')"
  _l="$_l $(fw_nft_addr_expr "$_dst" 'ip daddr')"
  case "$_p" in
    any|icmp)
      [ -z "$_sp" ] && [ -z "$_dp" ] || die 'Source and destination ports require TCP or UDP'
      [ "$_p" != icmp ] || _l="$_l meta l4proto icmp";;
    tcp|udp)
      if [ -n "$_sp$_dp" ]; then
        _l="$_l $(fw_nft_port_expr "$_p" sport "$_sp")"
        _l="$_l $(fw_nft_port_expr "$_p" dport "$_dp")"
      else
        _l="$_l meta l4proto $_p"
      fi;;
    *) die 'Protocol must be TCP, UDP, ICMP or any';;
  esac
  _c="lfw:$_id"; [ -z "$_d" ] || _c="$_c $_d"
  printf '%s %s comment "%s"\n' "$_l" "$_act" "$_c" | sed 's/^ *//;s/  */ /g'
}

# file helpers: find/remove/insert lines by rule id
fw_has_id() { grep -Eq "comment \"lfw:$2( |\"|$)" "$1"; }
fw_chain_of() { local _f; for _f in LFW_FWD LFW_IN LFW_OUT; do fw_has_id "$FWT/$_f" "$1" && { echo "$_f"; return 0; }; done; return 1; }
fw_index_of() { grep -En "comment \"lfw:$2( |\"|$)" "$1" | head -n 1 | cut -d: -f1; }
fw_remove_id() { grep -Ev "comment \"lfw:$2( |\"|$)" "$1" >"$1.n" || true; mv "$1.n" "$1"; }
# fw_insert FILE POS(0-based, empty=end) LINE
fw_insert() {
  printf '%s\n' "$3" >"$FWT/ins"
  if [ -z "$2" ]; then cat "$FWT/ins" >>"$1"; return; fi
  awk -v n="$2" -v f="$FWT/ins" 'NR==n+1{while((getline x < f)>0) print x; done=1} {print} END{if(!done) while((getline x < f)>0) print x}' "$1" >"$1.n"
  mv "$1.n" "$1"
}
chain_for() {
  case "$(lower "${1:-forward}")" in forward) echo LFW_FWD;; input) echo LFW_IN;; output) echo LFW_OUT;; *) die "chain must be forward, input or output";; esac
}
valid_pos() { [ -z "$1" ] || is_uint "$1" || die "invalid position"; }
valid_id() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}$' || die "invalid rule id"; }

op_rule_add() {
  _ch=$(fw_rule_chain); _pos=$(jget position); valid_pos "$_pos"
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
  _ch=$(fw_rule_chain)
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
  [ -n "$_in" ] || die 'no WAN segment is defined'
  need_fw_iface "$_in"
  _src=$(jget src); [ -z "$_src" ] || is_addr_match "$_src" || die 'invalid source IPv4, subnet or range'
  _p=$(lower "$(jget proto)"); [ -n "$_p" ] || _p=tcp
  _port=$(jget port); _to=$(jget to); _tp=$(jget toPort); _d=$(jget description)
  case "$_port" in *,*) die 'use a single port or a range';; esac
  is_ports "$_port" || die 'invalid external port'
  is_ipv4 "$_to" || die 'invalid internal IP address'
  if [ -n "$_tp" ]; then
    is_port "$_tp" || die 'invalid internal port'
    case "$_port" in *-*) die 'port range forwards to same ports';; esac
  fi
  is_desc "$_d" || die 'invalid description'
  case "$_p" in tcp) _ps=tcp;; udp) _ps=udp;; both) _ps="tcp udp";;
    *) die 'protocol must be tcp, udp or both';; esac
  _c="lfw:$_id"; [ -z "$_d" ] || _c="$_c $_d"
  _dest=$_to; [ -z "$_tp" ] || _dest="$_to:$_tp"
  for _x in $_ps; do
    _l="iifname \"$_in\""
    [ -z "$_src" ] || _l="$_l $(fw_nft_addr_expr "$_src" 'ip saddr')"
    printf '%s %s dport %s dnat ip to %s comment "%s"\n' \
      "$_l" "$_x" "$_port" "$_dest" "$_c"
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

# Firewall batch is nft-table-scoped, atomic and subject to confirmation.
fw_restore_snapshot() {
  local _restore _err
  _restore=$(mktemp)
  printf '%s\n' 'destroy table inet litefw' >"$_restore"
  cat "$1" >>"$_restore"
  if ! _err=$(nft -c -f "$_restore" 2>&1); then
    rm -f "$_restore"; echo "Cannot validate saved nftables snapshot: $_err" >&2
    return 1
  fi
  nft -f "$_restore" || { rm -f "$_restore"; return 1; }
  rm -f "$_restore"
}

# The raw baseline blocks overwriting changes from another administrator.
fw_pending_dir() { printf '%s/fw-pending' "$LFW_RUN"; }
fw_baseline() {
  fw_state | jq -c '{rules:[.rules[]|{id,chain,raw,managed}],forwards:[.forwards[]|{id,raw,managed}]}'
}
op_firewall_batch() {
  local base live orig item old index id chain file line changed before saved pending token
  local bodytmp seen entry kind oldchain oldid
  pending=$(fw_pending_dir)
  [ ! -f "$pending/pending" ] || die 'A firewall change is awaiting confirmation.'
  jq -e '(.baseline|type=="object") and (.rules|type=="array" and length<=200) and (.forwards|type=="array" and length<=100)' "$BODY" >/dev/null ||
    die 'Invalid firewall draft'
  base=$(jq -c '.baseline' "$BODY")
  live=$(fw_baseline)
  [ "$base" = "$live" ] ||
    die 'Firewall state has changed since opening this page. Discard edits and reload.'
  orig=$BODY
  before=$(mktemp); nft list table inet litefw >"$before" || die 'Cannot back up firewall'
  saved=$(mktemp)
  if [ -f "$LFW_FW_SAVE" ]; then cp "$LFW_FW_SAVE" "$saved"; else cp "$before" "$saved"; fi
  seen=$(mktemp); : >"$seen"
  bodytmp=$(mktemp)
  fw_snapshot
  : >"$FWT/LFW_FWD.new"; : >"$FWT/LFW_IN.new"; : >"$FWT/LFW_OUT.new"; : >"$FWT/LFW_ORDER.new"; : >"$FWT/LFW_DNAT.new"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    chain=$(printf '%s' "$item" | jq -r '.chain // ""')
    file=$(chain_for "$chain")
    index=$(printf '%s' "$item" | jq -r '.origin // -1')
    id=$(printf '%s' "$item" | jq -r '.id // ""')
    changed=$(printf '%s' "$item" | jq -r '.changed // false')
    if [ "$index" -ge 0 ]; then
      old=$(printf '%s' "$base" | jq -c --argjson i "$index" '.rules[$i] // empty')
      [ -n "$old" ] || die 'Unrecognized original rule'
      [ "$id" = "$(printf '%s' "$old" | jq -r .id)" ] || die 'Rule identifier mismatch'
      ! grep -Fxq "rule:$index" "$seen" || die 'Duplicate rule'
      echo "rule:$index" >>"$seen"
      if [ "$changed" = true ]; then
        printf '%s' "$old" | jq -e '.managed==true' >/dev/null || die 'Imported rule cannot be edited'
      else
        [ "$chain" = "$(printf '%s' "$old" | jq -r .chain)" ] || die 'Rule chain changed without editing'
      fi
    else
      [ -z "$id" ] || die 'New rule cannot supply an ID'
      id=$(new_id)
    fi
    if [ "$changed" = true ] || [ "$index" -lt 0 ]; then
      printf '%s
' "$item" >"$bodytmp"
      BODY=$bodytmp
      file=$(fw_rule_chain)
      line=$(fw_rule_line "$file" "$id") || die 'Invalid rule'
      BODY=$orig
    else
      line=$(printf '%s' "$old" | jq -r .raw)
    fi
    printf '%s
' "$line" >>"$FWT/$file.new"
    _index=$(( $(wc -l <"$FWT/$file.new") - 1 ))
    printf 'counter comment "lfw-order:%s:%s"
' "$file" "$_index" >>"$FWT/LFW_ORDER.new"
  done <<EOF
$(jq -c '.rules[]' "$orig")
EOF
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    index=$(printf '%s' "$item" | jq -r '.origin // -1')
    id=$(printf '%s' "$item" | jq -r '.id // ""')
    changed=$(printf '%s' "$item" | jq -r '.changed // false')
    if [ "$index" -ge 0 ]; then
      old=$(printf '%s' "$base" | jq -c --argjson i "$index" '.forwards[$i] // empty')
      [ -n "$old" ] || die 'Unrecognized original port forward'
      [ "$id" = "$(printf '%s' "$old" | jq -r .id)" ] || die 'Forward identifier mismatch'
      ! grep -Fxq "forward:$index" "$seen" || die 'Duplicate forward'
      echo "forward:$index" >>"$seen"
      if [ "$changed" = true ]; then
        printf '%s' "$old" | jq -e '.managed==true' >/dev/null || die 'Imported port forward cannot be edited'
      fi
    else
      [ -z "$id" ] || die 'New port forward cannot supply an ID'
      id=$(new_id)
    fi
    if [ "$changed" = true ] || [ "$index" -lt 0 ]; then
      printf '%s
' "$item" >"$bodytmp"
      BODY=$bodytmp
      line=$(fw_forward_lines "$id") || die 'Invalid forward'
      BODY=$orig
    else
      line=$(printf '%s' "$old" | jq -r .raw)
    fi
    printf '%s
' "$line" >>"$FWT/LFW_DNAT.new"
  done <<EOF
$(jq -c '.forwards[]' "$orig")
EOF
  mv "$FWT/LFW_FWD.new" "$FWT/LFW_FWD"
  mv "$FWT/LFW_IN.new" "$FWT/LFW_IN"
  mv "$FWT/LFW_OUT.new" "$FWT/LFW_OUT"
  mv "$FWT/LFW_ORDER.new" "$FWT/LFW_ORDER"
  mv "$FWT/LFW_DNAT.new" "$FWT/LFW_DNAT"
  mkdir -p "$pending"
  cp "$before" "$pending/before"
  cp "$saved" "$pending/boot"
  token=$(new_id)$(new_id)
  printf '%s
' "$token" >"$pending/pending"
  if ! (fw_commit); then
    rm -f "$pending/pending" "$pending/before" "$pending/boot"
    fw_restore_snapshot "$before" || true
    cp "$saved" "$LFW_FW_SAVE"
    die 'Firewall apply rejected; previous rules restored'
  fi
  # Before browser confirmation, reboot also recovers the old rules.
  cp "$saved" "$LFW_FW_SAVE"
  rm -f "$before" "$saved" "$bodytmp" "$seen"
  (
    exec 9>&- 2>/dev/null
    sleep "${LFW_FW_CONFIRM_TIMEOUT:-120}"
    if [ -f "$pending/pending" ] && [ "$(cat "$pending/pending")" = "$token" ]; then
      fw_restore_snapshot "$pending/before" &&
        cp "$pending/boot" "$LFW_FW_SAVE"
      rm -f "$pending/pending" "$pending/before" "$pending/boot"
    fi
  ) </dev/null >/dev/null 2>&1 &
  log_op 'firewall.batch applied; awaiting confirmation'
  jq -n --arg token "$token" --argjson seconds "${LFW_FW_CONFIRM_TIMEOUT:-120}" '{token:$token,confirmationSeconds:$seconds}' >"$RESULT"
}
op_firewall_confirm() {
  local pending token
  pending=$(fw_pending_dir)
  [ -f "$pending/pending" ] || die 'No firewall changes awaiting confirmation'
  token=$(jget token)
  [ -n "$token" ] && [ "$token" = "$(cat "$pending/pending")" ] ||
    die 'Confirmation token mismatch'
  { echo 'destroy table inet litefw'; nft list table inet litefw; } >"$LFW_FW_SAVE.tmp" &&
    mv "$LFW_FW_SAVE.tmp" "$LFW_FW_SAVE" || die 'Unable to save rules'
  rm -f "$pending/pending" "$pending/before" "$pending/boot"
  log_op 'firewall.batch confirmed'
}
