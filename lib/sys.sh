# shellcheck shell=sh
# System settings: hostname, management UI port/access, SSH, admin password.

web_bind_sync() {
  # The ISO includes this helper; legacy dev labs may not.
  command -v litefw-web-bind >/dev/null 2>&1 || return 0
  litefw-web-bind || die "failed to restrict the web listener to LAN addresses"
}
web_restart_after_reply() {
  command -v litefw-web-bind >/dev/null 2>&1 || return 0
  # Delayed so CGI can finish returning its response to the client.
  setsid sh -c 'sleep 1; rc-service lighttpd restart' >/dev/null 2>&1 </dev/null 9>&- &
}
mgmt_port() { sed -n 's/^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$LFW_LIGHTTPD_CONF" 2>/dev/null | head -n 1 | grep . || echo 80; }
ssh_port() { awk 'tolower($1)=="port"{print $2; exit}' "$LFW_SSHD_CONF" 2>/dev/null | grep . || echo 22; }
ssh_enabled() {
  # enabled = running now (the live state); boot runlevel is kept in step by mgmt.set
  pidof sshd >/dev/null 2>&1 || svc sshd status
}


# ------------------------------------------------------------- logging
# Alpine BusyBox syslogd is the source of truth. We read and update its native
# /etc/conf.d/syslog options instead of maintaining a LiteFWM settings database.
syslog_conf() { echo /etc/conf.d/syslog; }
syslog_opts() {
  local _f
  _f=$(syslog_conf)
  sed -n 's/^[[:space:]]*SYSLOGD_OPTS="\([^"]*\)".*/\1/p' "$_f" 2>/dev/null | head -n1
}

logging_json() {
  local _opts _remote _server _port _local _running
  _opts=$(syslog_opts)
  _remote="" _server="" _port=514 _local=true _running=false
  set -- $_opts
  while [ $# -gt 0 ]; do
    case "$1" in
      -R)
        shift
        [ $# -gt 0 ] && _remote=$1
        ;;
      -R*) _remote=${1#-R};;
    esac
    shift || true
  done
  if [ -n "$_remote" ]; then
    _local=false
    printf ' %s ' "$_opts" | grep -Eq ' -L( |$)' && _local=true
    case "$_remote" in
      *:*) _server=${_remote%:*}; _port=${_remote##*:};;
      *) _server=$_remote; _port=514;;
    esac
  fi
  svc syslog status && _running=true
  jq -n --arg server "$_server" --argjson port "$_port" \
    --argjson enabled "$([ -n "$_remote" ] && echo true || echo false)" \
    --argjson local "$_local" --argjson running "$_running" \
    '{remoteEnabled:$enabled,server:$server,port:$port,localEnabled:$local,protocol:"udp",serviceRunning:$running}'
}

# logging.set {remoteEnabled, server, port, localEnabled}
op_logging_set() {
  local _enabled _server _port _local _opts _new _tok _conf _tmp
  _enabled=$(jget remoteEnabled); [ -n "$_enabled" ] || _enabled=false
  case "$_enabled" in true|false) :;; *) die "remoteEnabled must be true or false";; esac
  _local=$(jget localEnabled); [ -n "$_local" ] || _local=true
  case "$_local" in true|false) :;; *) die "localEnabled must be true or false";; esac
  _server=$(jget server)
  _port=$(jget port); [ -n "$_port" ] || _port=514
  if [ "$_enabled" = true ]; then
    [ -n "$_server" ] || die "remote syslog server is required"
    is_ipv4 "$_server" || is_fqdn "$_server" || die "invalid remote syslog server"
    is_port "$_port" || die "invalid remote syslog port"
  fi

  # Preserve unrelated syslogd flags while replacing remote/local-forward flags.
  _opts=$(syslog_opts); _new=""
  set -- $_opts
  while [ $# -gt 0 ]; do
    _tok=$1; shift
    case "$_tok" in
      -R) [ $# -gt 0 ] && shift || true;;
      -R*|-L) :;;
      *) _new="${_new}${_new:+ }$_tok";;
    esac
  done
  if [ "$_enabled" = true ]; then
    _new="${_new}${_new:+ }-R $_server:$_port"
    [ "$_local" = true ] && _new="$_new -L"
  fi

  _conf=$(syslog_conf); _tmp=$(mktemp)
  if [ -r "$_conf" ]; then
    awk -v line="SYSLOGD_OPTS=\"$_new\"" '
      BEGIN{done=0}
      /^[[:space:]]*SYSLOGD_OPTS=/{if(!done){print line;done=1};next}
      {print}
      END{if(!done)print line}
    ' "$_conf" >"$_tmp"
  else
    printf 'SYSLOGD_OPTS="%s"\n' "$_new" >"$_tmp"
  fi
  install -m 0644 "$_tmp" "$_conf"; rm -f "$_tmp"
  svc_enable syslog boot
  svc syslog restart || svc syslog start || die "syslog service failed to restart"
  log_op "logging.set remote=$_enabled server=${_server:-none} port=$_port local=$_local"
  logging_json >"$RESULT"
}

client_iface() { # IP -> interface the client is reached through
  [ -n "$1" ] || return 0
  ip -4 route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

system_json() {
  local _up _load _mem _acc _dns _sshon _dm _cif _logging
  _up=$(awk '{print int($1)}' /proc/uptime)
  _load=$(cut -d' ' -f1-3 /proc/loadavg)
  _mem=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "{\"totalKb\":%d,\"availableKb\":%d}", t, a}' /proc/meminfo)
  fw_snapshot; _acc=$(mgmt_access_live | jq -R . | jq -s .); fw_cleanup
  _dns=$(awk '$1=="nameserver"{print $2}' /etc/resolv.conf 2>/dev/null | jq -R . | jq -s .)
  _sshon=false; ssh_enabled && _sshon=true
  _dm=false; dnsmasq_running && _dm=true
  _cif=$(client_iface "${LFW_CLIENT:-}")
  _logging=$(logging_json)
  jq -n --arg host "$(hostname)" --arg ver "$(cat "$LFW_LIB/VERSION" 2>/dev/null || echo dev)" \
    --arg kernel "$(uname -r)" --arg os "$(cat /etc/alpine-release 2>/dev/null || echo unknown)" \
    --argjson uptime "$_up" --arg load "$_load" --argjson mem "$_mem" \
    --argjson port "$(mgmt_port)" --argjson sshPort "$(ssh_port)" --argjson ssh "$_sshon" \
    --argjson access "$_acc" --argjson resolv "$_dns" --argjson dnsmasq "$_dm" \
    --arg fwd "$(cat /proc/sys/net/ipv4/ip_forward)" --arg cif "$_cif" --arg client "${LFW_CLIENT:-}" --argjson logging "$_logging" '
    { hostname: $host, version: $ver, kernel: $kernel, alpine: $os, uptime: $uptime,
      load: $load, memory: $mem, ipForward: ($fwd == "1"),
      management: { port: $port, access: $access, clientIp: $client, clientInterface: $cif },
      ssh: { enabled: $ssh, port: $sshPort },
      logging: $logging,
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
    web_bind_sync
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
    web_restart_after_reply
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

# ------------------------------------------------------------- Alpine APK packages
# These operations are intentionally distinct from the LiteFW runtime upgrade.
# They never change network topology, appliance services, or perform a reboot.
# The administrator must request both the check and the actual package upgrade.
packages_repositories() {
  [ -f /etc/apk/repositories ] ||
    die "No Alpine package repositories configured. Set official main/community repositories first."
  _repositories=$(grep -Ev '^[[:space:]]*(#|$)' /etc/apk/repositories || :)
  [ -n "$_repositories" ] ||
    die "Alpine package repositories are disabled. Configure official main/community repositories first."
}
packages_refresh() {
  packages_repositories
  _apkl=$(mktemp)
  if ! apk --timeout 12 update >"$_apkl" 2>&1; then
    _detail=$(tail -n 8 "$_apkl")
    rm -f "$_apkl"
    die "Alpine package index refresh failed: $_detail"
  fi
  rm -f "$_apkl"
}
packages_inventory() {
  _pkg_installed=$(apk list --installed 2>&1) ||
    die "Could not read installed Alpine packages: $_pkg_installed"
  _pkg_upgradable=$(apk list --upgradable 2>&1) ||
    die "Could not list available Alpine upgrades: $_pkg_upgradable"
  jq -n --arg all "$_pkg_installed" --arg updates "$_pkg_upgradable" '
    def parse_packages:
      split("\n") |
      map(select(test("^[^ ]+-[0-9][^ ]*-r[0-9]+[[:space:]]"))) |
      map(split(" ")[0] | try capture("^(?<name>.+)-(?<version>[0-9][^ ]*-r[0-9]+)$") catch empty) |
      unique_by(.name);
    ($all | parse_packages) as $installed |
    ($updates | parse_packages | INDEX(.name)) as $candidates |
    {
      installedCount: ($installed | length),
      upgradable: [$installed[] |
        select($candidates[.name] != null) |
        {name,installedVersion:.version,availableVersion:$candidates[.name].version}],
      current: [$installed[] |
        select($candidates[.name] == null) |
        {name,installedVersion:.version}]
    } |
    . + {upgradableCount:(.upgradable|length),currentCount:(.current|length)}'
}
op_packages_check() {
  packages_refresh
  packages_inventory >"$RESULT"
  _repo_json=$(printf '%s\n' "$_repositories" | jq -R -s 'split("\n") | map(select(length>0))')
  _tmp=$(mktemp)
  jq -n --argjson result "$(cat "$RESULT")" --argjson repos "$_repo_json" \
    --arg checkedAt "$(date -u +%FT%TZ)" '$result + {checkedAt:$checkedAt,repositories:$repos}' >"$_tmp"
  mv "$_tmp" "$RESULT"
}
op_packages_upgrade() {
  jbool confirmed || die "Confirm Alpine system package upgrades explicitly"
  packages_refresh
  _before=$(packages_inventory)
  _count=$(printf '%s' "$_before" | jq -r '.upgradableCount')
  if [ "$_count" -eq 0 ]; then
    jq -n --argjson before "$_before" '{upgraded:[],upgradedCount:0,rebootSuggested:false,
      remaining:$before.upgradable,currentCount:$before.currentCount,
      message:"All installed Alpine packages are already current."}' >"$RESULT"
    return
  fi
  _log=${LFW_APK_UPGRADE_LOG:-/var/log/litefw-alpine-upgrade.log}
  if ! apk --timeout 12 upgrade >"$_log" 2>&1; then
    die "Alpine package upgrade failed; check $_log: $(tail -n 8 "$_log")"
  fi
  _after=$(packages_inventory)
  jq -n --argjson before "$_before" --argjson after "$_after" --arg log "$_log" '
    ($after.current + $after.upgradable | INDEX(.name)) as $now |
    [$before.upgradable[] |
      select($now[.name] != null and $now[.name].installedVersion != .installedVersion) |
      {name,previousVersion:.installedVersion,
       installedVersion:$now[.name].installedVersion}] as $changed |
    {upgraded:$changed,upgradedCount:($changed|length),
     rebootSuggested: any($changed[]; .name | test("^(linux|linux-lts|linux-virt|musl|busybox|openrc)$")),
     remaining:$after.upgradable,remainingCount:$after.upgradableCount,
     currentCount:$after.currentCount,log:$log}' >"$RESULT"
  log_op "packages.upgrade packages=$_count"
}

# ------------------------------------------------------------- upgrades
# GitHub is a fixed trusted origin, never a caller-provided download URL.
LITEFW_RELEASE_REPO=theonemule/LITEFW2
LITEFW_RELEASES=https://api.github.com/repos/theonemule/LITEFW2/releases/latest

upgrade_version_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
upgrade_newer() {
  upgrade_version_ok "$1" && upgrade_version_ok "$2" || return 1
  printf '%s\n%s\n' "$1" "$2" | awk -F. 'NR==1{a=$1;b=$2;c=$3;next} {if(a!=$1) exit !(a>$1); if(b!=$2) exit !(b>$2); exit !(c>$3)}'
}
upgrade_latest() {
  command -v curl >/dev/null 2>&1 || die 'Update checks require curl; install it from the appliance ISO.'
  _json=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 15 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: LiteFW-updater' "$LITEFW_RELEASES") ||
    die 'Cannot reach the public LiteFW releases. Verify WAN/DNS connectivity and that the GitHub repository is public.'
  _latest=$(printf '%s' "$_json" | jq -r '.tag_name // empty' | sed 's/^v//')
  upgrade_version_ok "$_latest" || die 'Invalid version in GitHub release metadata'
  printf '%s\n' "$_latest"
}
op_upgrade_check() {
  _installed=$(cat "$LFW_LIB/VERSION")
  _latest=$(upgrade_latest)
  _available=false
  upgrade_newer "$_latest" "$_installed" && _available=true
  jq -n --arg installed "$_installed" --arg latest "$_latest" \
    --argjson available "$_available" --arg repo "$LITEFW_RELEASE_REPO" \
    '{installed:$installed,latest:$latest,available:$available,repository:$repo}' >"$RESULT"
}
upgrade_apply_file() {
  _input=$1
  [ -f "$_input" ] && [ ! -L "$_input" ] || die 'Upgrade archive is not a regular file'
  [ "$(wc -c <"$_input")" -le 4194304 ] || die 'Upgrade archive exceeds 4 MB limit'
  /usr/sbin/litefw-upgrade "$_input" > /tmp/litefw-upgrade-last.log 2>&1 || {
    die "Upgrade failed. Review /tmp/litefw-upgrade-last.log and /root/litefw-upgrade-backups/"
  }
  _new=$(cat "$LFW_LIB/VERSION")
  jq -n --arg version "$_new" '{version:$version,installed:true,rebootRequired:false}' >"$RESULT"
}
op_upgrade_install() {
  _current=$(cat "$LFW_LIB/VERSION")
  _latest=$(upgrade_latest)
  upgrade_newer "$_latest" "$_current" || die 'No newer published release is available'
  _file="litefw2-$_latest-runtime.tar.gz"
  _root=/root/litefw-upgrade-staging
  mkdir -p "$_root"
  chmod 0700 "$_root"
  _bundle="$_root/$_file"
  _url="https://github.com/$LITEFW_RELEASE_REPO/releases/download/v$_latest"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 45 \
    -o "$_root/SHA256SUMS" "$_url/SHA256SUMS" || die 'Could not download official release checksums'
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 45 \
    -o "$_bundle" "$_url/$_file" || die 'Could not download official runtime bundle'
  _want=$(awk -v file="$_file" '$2==file {print $1}' "$_root/SHA256SUMS" | head -1)
  printf '%s' "$_want" | grep -Eq '^[a-fA-F0-9]{64}$' || die 'Missing valid SHA-256 in release manifest'
  _got=$(sha256sum "$_bundle" | awk '{print $1}')
  [ "$_got" = "$_want" ] || die 'Release archive SHA-256 mismatch'
  upgrade_apply_file "$_bundle"
}
op_upgrade_upload() {
  _path=$(jget path)
  printf '%s' "$_path" | grep -Eq '^/tmp/litefw-upload[.][A-Za-z0-9]{6}$' || die 'Invalid upload path'
  [ -f "$_path" ] && [ ! -L "$_path" ] || die 'Uploaded bundle missing'
  [ "$(stat -c %U "$_path")" = lighttpd ] || die 'Upload owner mismatch'
  [ "$(wc -c <"$_path")" -le 4194304 ] || die 'Upload too large'
  install -d -m 0700 /root/litefw-upgrade-staging
  _target=$(mktemp /root/litefw-upgrade-staging/upload.XXXXXX.tar.gz)
  cp "$_path" "$_target"
  chmod 0600 "$_target"
  upgrade_apply_file "$_target"
}
