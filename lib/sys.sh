# shellcheck shell=sh
# System settings: hostname, management UI port/access, SSH, admin password.

mgmt_port() { sed -n 's/^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$LFW_LIGHTTPD_CONF" 2>/dev/null | head -n 1 | grep . || echo 80; }
ssh_port() { awk 'tolower($1)=="port"{print $2; exit}' "$LFW_SSHD_CONF" 2>/dev/null | grep . || echo 22; }
ssh_enabled() {
  # enabled = running now (the live state); boot runlevel is kept in step by mgmt.set
  pidof sshd >/dev/null 2>&1 || svc sshd status
}

client_iface() { # IP -> interface the client is reached through
  [ -n "$1" ] || return 0
  ip -4 route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

system_json() {
  local _up _load _mem _acc _dns _sshon _dm _cif
  _up=$(awk '{print int($1)}' /proc/uptime)
  _load=$(cut -d' ' -f1-3 /proc/loadavg)
  _mem=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "{\"totalKb\":%d,\"availableKb\":%d}", t, a}' /proc/meminfo)
  fw_snapshot; _acc=$(mgmt_access_live | jq -R . | jq -s .); fw_cleanup
  _dns=$(awk '$1=="nameserver"{print $2}' /etc/resolv.conf 2>/dev/null | jq -R . | jq -s .)
  _sshon=false; ssh_enabled && _sshon=true
  _dm=false; dnsmasq_running && _dm=true
  _cif=$(client_iface "${LFW_CLIENT:-}")
  jq -n --arg host "$(hostname)" --arg ver "$(cat "$LFW_LIB/VERSION" 2>/dev/null || echo dev)" \
    --arg kernel "$(uname -r)" --arg os "$(cat /etc/alpine-release 2>/dev/null || echo unknown)" \
    --argjson uptime "$_up" --arg load "$_load" --argjson mem "$_mem" \
    --argjson port "$(mgmt_port)" --argjson sshPort "$(ssh_port)" --argjson ssh "$_sshon" \
    --argjson access "$_acc" --argjson resolv "$_dns" --argjson dnsmasq "$_dm" \
    --arg fwd "$(cat /proc/sys/net/ipv4/ip_forward)" --arg cif "$_cif" --arg client "${LFW_CLIENT:-}" '
    { hostname: $host, version: $ver, kernel: $kernel, alpine: $os, uptime: $uptime,
      load: $load, memory: $mem, ipForward: ($fwd == "1"),
      management: { port: $port, access: $access, clientIp: $client, clientInterface: $cif },
      ssh: { enabled: $ssh, port: $sshPort },
      resolvers: $resolv, services: { dnsmasq: $dnsmasq } }'
}

op_system_set() {
  _h=$(jget hostname)
  if [ -n "$_h" ]; then
    is_hostname "$_h" || die "invalid hostname"
    run hostname "$_h"
    echo "$_h" >/etc/hostname
    if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $_h/" /etc/hosts
    else
      echo "127.0.1.1 $_h" >>/etc/hosts
    fi
  fi
  log_op "system.set hostname=$_h"
}

# mgmt.set {port, sshEnabled, sshPort, access: "any" | [iface...]}
op_mgmt_set() {
  _port=$(jget port); _sp=$(jget sshPort)
  [ -z "$_port" ] || is_port "$_port" || die "invalid management port"
  [ -z "$_sp" ] || is_port "$_sp" || die "invalid SSH port"
  [ -z "$_port" ] || [ -z "$_sp" ] || [ "$_port" != "$_sp" ] || die "management and SSH ports must differ"
  _acc=""
  if jhas access; then
    if [ "$(jq -r '.access|type' "$BODY")" = string ]; then
      [ "$(jget access)" = any ] || die "access must be \"any\" or a list of interfaces"
      _acc=any
    else
      _acc=$(jlist access | tr '\n' ' ')
      [ -n "$_acc" ] || die "management access needs at least one interface (or any)"
      for _i in $_acc; do need_fw_iface "$_i"; done
      _cif=$(client_iface "${LFW_CLIENT:-}")
      if [ -n "$_cif" ] && ! printf '%s\n' $_acc | grep -Fxq "$_cif"; then
        die "refusing to lock you out: your session arrives on $_cif, which is not in the access list"
      fi
    fi
  fi
  _restart_web=false
  if [ -n "$_port" ] && [ "$_port" != "$(mgmt_port)" ]; then
    sed -i "s/^[[:space:]]*server\.port[[:space:]]*=.*/server.port = $_port/" "$LFW_LIGHTTPD_CONF"
    lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null 2>&1 || die "lighttpd rejected port $_port"
    _restart_web=true
  fi
  if [ -n "$_sp" ] && [ "$_sp" != "$(ssh_port)" ]; then
    if grep -Eqi '^[[:space:]]*Port[[:space:]]' "$LFW_SSHD_CONF"; then
      sed -i -E "s/^[[:space:]]*[Pp]ort[[:space:]].*/Port $_sp/" "$LFW_SSHD_CONF"
    else
      echo "Port $_sp" >>"$LFW_SSHD_CONF"
    fi
    if command -v sshd >/dev/null 2>&1; then sshd -t 2>/dev/null || die "sshd rejected the new configuration"; fi
    ! ssh_enabled || svc sshd restart || warn "sshd did not restart"
  fi
  if jhas sshEnabled; then
    if jbool sshEnabled; then
      svc sshd start || ssh_enabled || die "sshd failed to start"
      svc_enable sshd default
    else
      svc sshd stop || true
      try rc-update del sshd default
      try pkill -x sshd
    fi
  fi
  fw_snapshot
  if [ -n "$_acc" ]; then
    # shellcheck disable=SC2086
    fw_commit $_acc
  else
    fw_commit
  fi
  if [ "$_restart_web" = true ]; then
    # restart after this response has been delivered
    setsid sh -c 'sleep 1; rc-service lighttpd restart' >/dev/null 2>&1 </dev/null 9>&- &
    warn "the management UI moves to port $_port; reconnect at the new port"
  fi
  log_op "mgmt.set port=$_port ssh=$(jget sshEnabled) sshPort=$_sp access=$_acc"
}

# password.set {user, password}
op_password_set() {
  _u=$(jget user); _p=$(jq -r '.password // ""' "$BODY")
  printf '%s' "$_u" | grep -Eq '^[A-Za-z0-9_.-]{1,32}$' || die "invalid user name"
  [ "${#_p}" -ge 8 ] || die "password must be at least 8 characters"
  printf '%s\n' "$_p" | htpasswd -i "$LFW_HTPASSWD" "$_u" >/dev/null 2>&1 || die "could not update password"
  chown root:lighttpd "$LFW_HTPASSWD" 2>/dev/null || true
  chmod 0640 "$LFW_HTPASSWD"
  log_op "password.set $_u"
}

op_diag_ping() {
  _h=$(jget host); is_fqdn "$_h" || is_ipv4 "$_h" || die "invalid host"
  _o=$(ping -c 3 -W 2 "$_h" 2>&1 || true)
  jq -n --arg o "$_o" '{output:$o}' >"$RESULT"
}
op_diag_lookup() {
  _h=$(jget host); is_fqdn "$_h" || die "invalid host"
  _o=$(nslookup "$_h" 127.0.0.1 2>&1 || true)
  jq -n --arg o "$_o" '{output:$o}' >"$RESULT"
}
