# shellcheck shell=sh
# Optional modules are package-on-demand extensions. Their truth is the native
# package/service/configuration state, never a LiteFWM registry.
if [ -d "$LFW_LIB/modules" ]; then
  LFW_MODULE_DIR="$LFW_LIB/modules"
else
  LFW_MODULE_DIR="$LFW_LIB/../modules"
fi

module_id_ok() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$'; }
module_script() {
  module_id_ok "$1" || die "invalid module id"
  _mf="$LFW_MODULE_DIR/$1/module.sh"
  [ -x "$_mf" ] || die "unknown module: $1"
  printf '%s
' "$_mf"
}
module_call() {
  _mid=$1; shift
  _mf=$(module_script "$_mid")
  "$_mf" installed >/dev/null 2>&1 || die "module is not installed: $_mid"
  "$_mf" "$@"
}
module_csv() { jlist "$1" | paste -sd, -; }

module_json() {
  _mid=$1
  _mf=$(module_script "$_mid")
  _meta=$("$_mf" meta 2>/dev/null) || die "could not read module metadata: $_mid"
  if "$_mf" installed >/dev/null 2>&1; then
    _ins=true
    _state=$("$_mf" snapshot 2>/dev/null || echo '{}')
    if [ "$_mid" = ddns ]; then
      _providers=$("$_mf" providers 2>/dev/null | jq '[.[] | if type == "string" then . else (.name // .id // empty) end] | unique' 2>/dev/null || echo '[]')
      _state=$(jq -n --argjson s "$_state" --argjson p "$_providers" '$s + {providers:$p}')
    fi
  else
    _ins=false
    _state='{}'
  fi
  jq -n --argjson m "$_meta" --argjson i "$_ins" --argjson s "$_state" '$m + {installed:$i,state:$s}'
}

modules_catalog_json() {
  {
    for _mf in "$LFW_MODULE_DIR"/*/module.sh; do
      [ -x "$_mf" ] || continue
      _meta=$("$_mf" meta 2>/dev/null) || continue
      if "$_mf" installed >/dev/null 2>&1; then _ins=true; else _ins=false; fi
      jq -n --argjson m "$_meta" --argjson i "$_ins" '$m + {installed:$i,state:{}}'
    done
  } | jq -s 'sort_by(.name)'
}

modules_json() {
  {
    for _mf in "$LFW_MODULE_DIR"/*/module.sh; do
      [ -x "$_mf" ] || continue
      _id=$("$_mf" meta 2>/dev/null | jq -r '.id') || continue
      module_json "$_id"
    done
  } | jq -s 'sort_by(.name)'
}

module_firewall_rules() {
  for _mf in "$LFW_MODULE_DIR"/*/module.sh; do
    [ -x "$_mf" ] || continue
    "$_mf" installed >/dev/null 2>&1 || continue
    "$_mf" firewall 2>/dev/null || true
  done
}
module_sync_firewall() { command -v fw_sync >/dev/null 2>&1 && fw_sync; }

op_module_install() {
  _id=$(jget id); _mf=$(module_script "$_id")
  if "$_mf" installed >/dev/null 2>&1; then
    printf '{"alreadyInstalled":true}' >"$RESULT"
    return
  fi
  "$_mf" install
  module_sync_firewall
  log_op "module.install $_id"
  printf '{"installed":true}' >"$RESULT"
}
op_module_remove() {
  _id=$(jget id); _mf=$(module_script "$_id")
  if ! "$_mf" installed >/dev/null 2>&1; then
    printf '{"alreadyRemoved":true}' >"$RESULT"
    return
  fi
  "$_mf" uninstall
  module_sync_firewall
  log_op "module.remove $_id"
  printf '{"removed":true}' >"$RESULT"
}

op_bind_settings() {
  _min=no
  jbool minimalResponses && _min=yes
  module_call bind settings-set "$(module_csv listenAddresses)" "$(module_csv allowQuery)" \
    "$(module_csv allowTransfer)" "$(jget recursion)" "$(module_csv recursiveClients)" "$(module_csv forwarders)" \
    "$(jget forwardMode)" "$(jget dnssecValidation)" "$_min" "$(jget maxCacheTtl)" \
    "$(jget maxNegativeTtl)" "$(jget listenIPv6)"
  module_sync_firewall
  log_op "bind.settings"
}
op_bind_zoneadd() {
  module_call bind zone-add "$(jget name)" "$(jget primaryNs)" "$(jget primaryNsAddress)" "$(jget admin)" \
    "$(jget ttl)" "$(jget refresh)" "$(jget retry)" "$(jget expire)" "$(jget minimum)"
  module_sync_firewall
  log_op "bind.zoneadd $(jget name)"
}
op_bind_zonedelete() {
  _z=$(jget name)
  module_call bind zone-delete "$_z"
  module_sync_firewall
  log_op "bind.zonedelete $_z"
}
op_bind_zoneread() {
  _z=$(jget zone)
  _json=$(module_call bind zone-source "$_z")
  printf '%s' "$_json" >"$RESULT"
}
op_bind_zonewrite() {
  _z=$(jget zone); _sha=$(jget expectedSha); _create=$(jget create)
  case "$_create" in true|false) :;; *) die "Invalid zone creation flag";; esac
  jq -e '.source|type=="string" and (length>0) and (length<=65536)' "$BODY" >/dev/null ||
    die "A zone file (max 64 KiB) is required"
  _src=$(mktemp)
  jq -j '.source' "$BODY" >"$_src"
  _out=$(module_call bind zone-write "$_z" "$_sha" "$_create" <"$_src") ||
    { rm -f "$_src"; die "BIND refused this zone file"; }
  rm -f "$_src"
  printf '%s' "$_out" >"$RESULT"
  log_op "bind.zonewrite $_z"
}
op_bind_recordadd() {
  _out=$(module_call bind record-add "$(jget zone)" "$(jget name)" "$(jget type)" "$(jget value)" "$(jget ttl)" "$(jget priority)")
  printf '%s' "$_out" >"$RESULT"
  log_op "bind.recordadd $(jget zone)"
}
op_bind_recorddelete() {
  module_call bind record-delete "$(jget zone)" "$(jget id)"
  log_op "bind.recorddelete $(jget zone)"
}
op_bind_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "action must be start, stop or restart";; esac
  module_call bind service "$_a"
  module_sync_firewall
  log_op "bind.service $_a"
}

op_openvpn_server() {
  _in=$(jget inboundInterface); [ -n "$_in" ] || _in=wan
  _dev=$(jget interface); [ -n "$_dev" ] || _dev=tun0
  _proto=$(jget protocol); [ -n "$_proto" ] || _proto=udp
  _port=$(jget port); [ -n "$_port" ] || _port=1194
  module_call openvpn server-set "$(jget publicHost)" "$_in" "$_dev" "$_proto" "$_port"     "$(jget network)" "$(module_csv dns)" "$(module_csv routes)" "$(jget redirectGateway)" "$(jget clientToClient)"
  module_sync_firewall
  log_op "openvpn.server $_dev $_proto/$_port"
}
op_openvpn_clientadd() {
  _out=$(module_call openvpn client-add "$(jget name)")
  printf '%s' "$_out" >"$RESULT"
  log_op "openvpn.clientadd $(jget name)"
}
op_openvpn_clientrevoke() {
  module_call openvpn client-revoke "$(jget name)"
  log_op "openvpn.clientrevoke $(jget name)"
}
op_openvpn_profile() {
  _p=$(module_call openvpn client-profile "$(jget name)")
  jq -n --arg profile "$_p" '{profile:$profile}' >"$RESULT"
}
op_openvpn_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "action must be start, stop or restart";; esac
  module_call openvpn service "$_a"
  module_sync_firewall
  log_op "openvpn.service $_a"
}

op_ddns_configure() {
  _check=$(jq -r '.custom.checkServer // ""' "$BODY")
  _checkpath=$(jq -r '.custom.checkPath // ""' "$BODY")
  _update=$(jq -r '.custom.updateServer // ""' "$BODY")
  _updatepath=$(jq -r '.custom.updatePath // ""' "$BODY")
  _ssl=$(jq -r 'if .custom.ssl == null then true else .custom.ssl end' "$BODY")
  module_call ddns configure "$(jget provider)" "$(module_csv hostnames)" "$(jget username)" "$(jget password)"     "$(jget period)" "$(jget interface)" "$_check" "$_checkpath" "$_update" "$_updatepath" "$_ssl"
  log_op "ddns.configure $(jget provider)"
}
op_ddns_force() {
  _out=$(module_call ddns force-update 2>&1)
  jq -n --arg output "$_out" '{output:$output}' >"$RESULT"
  log_op "ddns.force"
}
op_ddns_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "action must be start, stop or restart";; esac
  module_call ddns service "$_a"
  log_op "ddns.service $_a"
}
