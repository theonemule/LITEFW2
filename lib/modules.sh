# shellcheck shell=sh
# Optional modules are package-on-demand extensions. Their truth is the native
# package/service/configuration state, never a LiteFWM registry.
if [ -d "$LFW_LIB/modules" ]; then
  LFW_MODULE_DIR="$LFW_LIB/modules"
else
  LFW_MODULE_DIR="$LFW_LIB/../modules"
fi

module_id_ok() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$'; }
module_manifest_entry() {
  module_id_ok "$1" || die "invalid module id"
  [ -r "$LFW_MODULE_DIR/manifest.json" ] || die "module catalog is missing; reinstall the LiteFW runtime"
  jq -ec --arg id "$1" '.modules[] | select(.id == $id)' "$LFW_MODULE_DIR/manifest.json" ||
    die "unknown module: $1"
}
module_script() {
  module_id_ok "$1" || die "invalid module id"
  _entry=$(module_manifest_entry "$1")
  _rel=$(printf '%s' "$_entry" | jq -r '.scripts.controller // empty')
  [ "$_rel" = "$1/module.sh" ] || die "invalid controller path for module $1"
  _mf="$LFW_MODULE_DIR/$_rel"
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
  _manifest=$(module_manifest_entry "$_mid")
  _meta=$(jq -n --argjson m "$_meta" --argjson entry "$_manifest" '$m + {core:$entry.core,packages:$entry.packages,version:$entry.version}')
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
      _id=$(printf '%s' "$_meta" | jq -r '.id')
      _manifest=$(module_manifest_entry "$_id")
      _meta=$(jq -n --argjson m "$_meta" --argjson entry "$_manifest" '$m + {core:$entry.core,packages:$entry.packages,version:$entry.version}')
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
module_sync_firewall() { if command -v fw_sync >/dev/null 2>&1; then fw_sync; fi; }

op_module_install() {
  _id=$(jget id); _mf=$(module_script "$_id")
  if "$_mf" installed >/dev/null 2>&1; then
    printf '{"alreadyInstalled":true}' >"$RESULT"
    return
  fi
  _entry=$(module_manifest_entry "$_id")
  [ "$(printf '%s' "$_entry" | jq -r '.core')" != true ] ||
    die "$_id is bundled with LiteFW and cannot be installed separately"
  _installer_rel=$(printf '%s' "$_entry" | jq -r '.scripts.install // empty')
  [ "$_installer_rel" = "$_id/install.sh" ] || die "invalid installer path for $_id"
  _installer="$LFW_MODULE_DIR/$_installer_rel"
  [ -x "$_installer" ] || die "Module installer missing: $_id"
  "$_installer"
  for _pkg in $(printf '%s' "$_entry" | jq -r '.packages[]'); do
    apk info -e "$_pkg" >/dev/null 2>&1 ||
      die "Installer returned success but required package $_pkg is not installed"
  done
  "$_mf" installed >/dev/null 2>&1 ||
    die "Installer exited but $_id is not installed (check Alpine packages and OpenRC service)"
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
  _entry=$(module_manifest_entry "$_id")
  [ "$(printf '%s' "$_entry" | jq -r '.core')" != true ] ||
    die "$_id is a core LiteFW dependency and cannot be removed"
  _uninstaller_rel=$(printf '%s' "$_entry" | jq -r '.scripts.remove // empty')
  [ "$_uninstaller_rel" = "$_id/uninstall.sh" ] || die "invalid removal path for $_id"
  _uninstaller="$LFW_MODULE_DIR/$_uninstaller_rel"
  [ -x "$_uninstaller" ] || die "Module uninstaller missing: $_id"
  "$_uninstaller"
  if "$_mf" installed >/dev/null 2>&1; then
    die "Module removal returned without removing $_id"
  fi
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
op_bind_zonerecords() {
  _out=$(module_call bind zone-records "$(jget zone)")
  printf '%s' "$_out" >"$RESULT"
}
op_bind_recordchange() {
  _out=$(module_call bind record-change "$(jget zone)" "$(jget expectedSha)" "$(jget index)" "$(jget action)" \
    "$(jget name)" "$(jget type)" "$(jget value)" "$(jget ttl)" "$(jget priority)")
  printf '%s' "$_out" >"$RESULT"
  log_op "bind.recordchange $(jget zone)"
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
op_openvpn_instanceadd() {
  module_call openvpn instance-save "$BODY" >"$RESULT" || die "OpenVPN client profile invalid or could not be saved"
  log_op "openvpn.instanceadd $(jget id)"
}
op_openvpn_instancedelete() {
  module_call openvpn instance-delete "$(jget id)" || die "Could not remove OpenVPN client tunnel"
  log_op "openvpn.instancedelete $(jget id)"
}
op_openvpn_instanceservice() {
  _action=$(jget action)
  case "$_action" in start|stop|restart) :;; *) die "Invalid OpenVPN client action";; esac
  module_call openvpn instance-service "$(jget id)" "$_action" || die "OpenVPN client service action failed"
  log_op "openvpn.instanceservice $(jget id) $_action"
}
op_openvpn_sitepeeradd() {
  module_call openvpn site-peer-save "$BODY" >"$RESULT" || die "OpenVPN site peer configuration failed"
  log_op "openvpn.sitepeeradd $(jget id)"
}
op_openvpn_sitepeerdelete() {
  module_call openvpn site-peer-delete "$(jget id)" || die "OpenVPN site peer removal failed"
  log_op "openvpn.sitepeerdelete $(jget id)"
}
op_ipsec_tunnelset() {
  module_call ipsec tunnel-save "$BODY" >"$RESULT" || die "IPsec tunnel validation or save failed"
  log_op "ipsec.tunnelset $(jget id)"
}
op_ipsec_tunneldelete() {
  module_call ipsec tunnel-delete "$(jget id)" || die "IPsec tunnel removal failed"
  module_sync_firewall
  log_op "ipsec.tunneldelete $(jget id)"
}
op_ipsec_tunnelstart() {
  module_call ipsec tunnel-start "$(jget id)" >"$RESULT" || die "IPsec tunnel negotiation failed"
  log_op "ipsec.tunnelstart $(jget id)"
}
op_ipsec_tunnelstop() {
  module_call ipsec tunnel-stop "$(jget id)" || die "Could not stop IPsec tunnel"
  log_op "ipsec.tunnelstop $(jget id)"
}
op_ipsec_service() {
  _action=$(jget action)
  case "$_action" in start|stop|restart) :;; *) die "Invalid IPsec service action";; esac
  module_call ipsec service "$_action" || die "IPsec service operation failed"
  module_sync_firewall
  log_op "ipsec.service $_action"
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
op_ddns_cfconfigure() {
  # Explicit failure handling is mandatory: lfwctl uses set -u, not set -e.
  # A failed provider validation must never be logged as a successful save.
  module_call ddns cloudflare-configure "$BODY" >"$RESULT" ||
    die "Cloudflare validation failed; no configuration changes were saved"
  jq -e 'type == "object" and .credentialConfigured == true' "$RESULT" >/dev/null 2>&1 ||
    die "Cloudflare configuration handler did not return a valid result"
  log_op "ddns.cfconfigure"
}
op_ddns_cfcheck() {
  _out=$(module_call ddns cloudflare-check) || die "Cloudflare record check failed"
  jq -n --arg output "$_out" '{output:$output}' >"$RESULT"
  log_op "ddns.cfcheck"
}
op_ddns_cfupdate() {
  _out=$(module_call ddns cloudflare-update) || die "Cloudflare DNS refresh failed"
  jq -n --arg output "$_out" '{output:$output}' >"$RESULT"
  log_op "ddns.cfupdate"
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

op_suricata_configure() {
  module_call suricata configure "$BODY" >"$RESULT" || die "suricata configuration failed"
  module_sync_firewall
  log_op "suricata.configure"
}
op_suricata_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call suricata service "$_a" >"$RESULT" || die "suricata service action failed"
  module_sync_firewall
  log_op "suricata.service $_a"
}

op_geoip_configure() {
  module_call geoip configure "$BODY" >"$RESULT" || die "geoip configuration failed"
  module_sync_firewall
  log_op "geoip.configure"
}
op_geoip_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call geoip service "$_a" >"$RESULT" || die "geoip service action failed"
  module_sync_firewall
  log_op "geoip.service $_a"
}

op_crowdsec_configure() {
  module_call crowdsec configure "$BODY" >"$RESULT" || die "crowdsec configuration failed"
  module_sync_firewall
  log_op "crowdsec.configure"
}
op_crowdsec_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call crowdsec service "$_a" >"$RESULT" || die "crowdsec service action failed"
  module_sync_firewall
  log_op "crowdsec.service $_a"
}

op_wireguard_configure() {
  module_call wireguard configure "$BODY" >"$RESULT" || die "wireguard configuration failed"
  module_sync_firewall
  log_op "wireguard.configure"
}
op_wireguard_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call wireguard service "$_a" >"$RESULT" || die "wireguard service action failed"
  module_sync_firewall
  log_op "wireguard.service $_a"
}

op_cloudflared_configure() {
  module_call cloudflared configure "$BODY" >"$RESULT" || die "cloudflared configuration failed"
  module_sync_firewall
  log_op "cloudflared.configure"
}
op_cloudflared_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call cloudflared service "$_a" >"$RESULT" || die "cloudflared service action failed"
  module_sync_firewall
  log_op "cloudflared.service $_a"
}

op_multiwan_configure() {
  module_call multiwan configure "$BODY" >"$RESULT" || die "multiwan configuration failed"
  module_sync_firewall
  log_op "multiwan.configure"
}
op_multiwan_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call multiwan service "$_a" >"$RESULT" || die "multiwan service action failed"
  module_sync_firewall
  log_op "multiwan.service $_a"
}

op_mdns_configure() {
  module_call mdns configure "$BODY" >"$RESULT" || die "mdns configuration failed"
  module_sync_firewall
  log_op "mdns.configure"
}
op_mdns_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call mdns service "$_a" >"$RESULT" || die "mdns service action failed"
  module_sync_firewall
  log_op "mdns.service $_a"
}

op_captive_configure() {
  module_call captive configure "$BODY" >"$RESULT" || die "captive configuration failed"
  module_sync_firewall
  log_op "captive.configure"
}
op_captive_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call captive service "$_a" >"$RESULT" || die "captive service action failed"
  module_sync_firewall
  log_op "captive.service $_a"
}

op_frr_configure() {
  module_call frr configure "$BODY" >"$RESULT" || die "frr configuration failed"
  module_sync_firewall
  log_op "frr.configure"
}
op_frr_service() {
  _a=$(jget action)
  case "$_a" in start|stop|restart) :;; *) die "Invalid service action";; esac
  module_call frr service "$_a" >"$RESULT" || die "frr service action failed"
  module_sync_firewall
  log_op "frr.service $_a"
}

op_geoip_refresh() {
  module_call geoip refresh >"$RESULT" || die 'GeoIP feed update failed'
  module_sync_firewall
  log_op 'geoip.refresh'
}

# Extend SNAT to all configured backup WAN devices only when failover enabled.
module_firewall_snat_rules() {
  _primary=${1:-}
  _file="${LFW_MODULE_CONFIG_DIR:-/etc/litefw-addons}/multiwan.json"
  [ -r "$_file" ] || return 0
  [ "$(jq -r '.enabled // false' "$_file" 2>/dev/null)" = true ] || return 0
  jq -r '.uplinks[].interface' "$_file" | sort -u | while IFS= read -r _iface; do
    is_ifname "$_iface" || continue
    [ "$_iface" = "$_primary" ] && continue
    printf '%s\n' "-A LFW_SNAT -o $_iface -j MASQUERADE"
  done
}
op_suricata_rulesupdate() {
  module_call suricata rules-update >"$RESULT" || die 'Suricata rule feed update failed'
  log_op 'suricata.rulesupdate'
}

op_crowdsec_decisionssync() {
  module_call crowdsec decisions-sync >"$RESULT" || die 'CrowdSec decision sync failed'
  module_sync_firewall
  log_op 'crowdsec.decisionssync'
}
