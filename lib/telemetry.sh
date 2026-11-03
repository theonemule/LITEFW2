# shellcheck shell=sh
# LiteFW telemetry: opt-in Prometheus exposition and OTLP/HTTP push.
# The authenticated management listener already enforces LAN-only access.
LFW_TELEM_CONF=${LFW_TELEM_CONF:-/etc/litefwm/telemetry.json}
telemetry_json(){
  if [ -r "$LFW_TELEM_CONF" ]; then
    jq '{prometheus:(.prometheus//false),otlpEnabled:(.otlpEnabled//false),
      endpoint:(.endpoint//""),intervalMinutes:(.intervalMinutes//5),
      tokenConfigured:((.token//"")!="")}' "$LFW_TELEM_CONF"
  else
    echo '{"prometheus":false,"otlpEnabled":false,"endpoint":"","intervalMinutes":5,"tokenConfigured":false}'
  fi
}
telemetry_samples(){
  # Only bounded OS counters; no addresses, user data, hostnames, or credentials.
  local _up
  _up=$(cut -d' ' -f1 /proc/uptime | awk '{printf "%.0f",$1}')
  printf 'litefw_uptime_seconds %s\n' "$_up"
  if [ -r /proc/loadavg ]; then
    read -r one rest < /proc/loadavg
    printf 'litefw_load1 %s\n' "$one"
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -s -j link show 2>/dev/null | jq -r '
      .[] | select(.ifname|test("^[A-Za-z0-9_.:-]{1,32}$")) |
      "litefw_interface_receive_bytes{interface=\"\(.ifname)\"} \(.stats64.rx.bytes // .stats.rx.bytes // 0)\n"+
      "litefw_interface_transmit_bytes{interface=\"\(.ifname)\"} \(.stats64.tx.bytes // .stats.tx.bytes // 0)"'
  fi
}
telemetry_metrics(){
  [ -r "$LFW_TELEM_CONF" ] && [ "$(jq -r '.prometheus//false' "$LFW_TELEM_CONF")" = true ] ||
    die 'Prometheus exporter disabled in System > Telemetry'
  printf '# HELP litefw_uptime_seconds Uptime of the firewall in seconds\n# TYPE litefw_uptime_seconds gauge\n'
  printf '# TYPE litefw_load1 gauge\n# TYPE litefw_interface_receive_bytes counter\n# TYPE litefw_interface_transmit_bytes counter\n'
  telemetry_samples
}
telemetry_otlp(){
  local _stamp _up _load
  _stamp="$(date +%s)000000000"
  _up=$(cut -d' ' -f1 /proc/uptime)
  _load=$(awk '{print $1}' /proc/loadavg)
  jq -n --arg stamp "$_stamp" --argjson uptime "$_up" --argjson load "$_load" '{
    resourceMetrics:[{resource:{attributes:[{key:"service.name",value:{stringValue:"litefw"}}]},
      scopeMetrics:[{scope:{name:"litefw.telemetry"},
        metrics:[
          {name:"litefw.uptime",unit:"s",gauge:{dataPoints:[{timeUnixNano:$stamp,asDouble:$uptime}]}},
          {name:"litefw.load1",gauge:{dataPoints:[{timeUnixNano:$stamp,asDouble:$load}]}}
        ]}]}]}'
}
op_telemetry_set(){
  local _endpoint _enabled _prom _minutes _token _tmp
  _prom=$(jget prometheus); [ -n "$_prom" ] || _prom=false
  _enabled=$(jget otlpEnabled); [ -n "$_enabled" ] || _enabled=false
  case "$_prom:$_enabled" in true:true|true:false|false:true|false:false) :;; *) die 'Invalid telemetry flags';; esac
  _endpoint=$(jget endpoint)
  _minutes=$(jget intervalMinutes); [ -n "$_minutes" ] || _minutes=5
  case "$_minutes" in 5|15|30|60) :;; *) die 'Telemetry interval must be 5, 15, 30, or 60 minutes';; esac
  if [ "$_enabled" = true ]; then
    printf '%s' "$_endpoint" | grep -Eq '^https://[a-zA-Z0-9][a-zA-Z0-9._:-]+(/[a-zA-Z0-9._/-]*)?$' ||
      die 'OTLP endpoint must be an HTTPS URL with no query/userinfo'
    case "$_endpoint" in */v1/metrics) :;; *) die 'OTLP HTTP endpoint must end in /v1/metrics';; esac
    command -v curl >/dev/null 2>&1 || die 'curl required for OTLP; install Alpine curl package'
  fi
  mkdir -p /etc/litefwm
  _token=$(jget token)
  if [ -z "$_token" ] && [ -r "$LFW_TELEM_CONF" ]; then _token=$(jq -r '.token//""' "$LFW_TELEM_CONF"); fi
  # Credentials may not contain CR/LF, quotes or shell metacharacters; the
  # credential stays in a root-only curl config, never in process arguments.
  [ -z "$_token" ] || printf '%s' "$_token" | grep -Eq '^[A-Za-z0-9._~+/=:-]{1,1024}$' ||
    die 'Token contains unsupported characters'
  _tmp=$(mktemp)
  jq -n --argjson prometheus "$_prom" --argjson otlpEnabled "$_enabled"     --arg endpoint "$_endpoint" --argjson intervalMinutes "$_minutes" --arg token "$_token"     '{prometheus:$prometheus,otlpEnabled:$otlpEnabled,endpoint:$endpoint,intervalMinutes:$intervalMinutes,token:$token}' >"$_tmp"
  install -m 0600 "$_tmp" "$LFW_TELEM_CONF"; rm -f "$_tmp"
  if [ "$_enabled" = true ]; then
    { printf 'url = "%s"\n' "$_endpoint"
      printf 'header = "Content-Type: application/json"\n'
      [ -z "$_token" ] || printf 'header = "Authorization: Bearer %s"\n' "$_token"
    } | install -m 0600 /dev/stdin /etc/litefwm/telemetry.curl
  else rm -f /etc/litefwm/telemetry.curl; fi
  # Cron worker checks interval itself and never exposes credentials in argv.
  mkdir -p /etc/periodic/5min
  install -m 0755 "$LFW_LIB/telemetry-cron.sh" /etc/periodic/5min/litefw-telemetry
  mkdir -p /etc/crontabs
  if [ -r /etc/crontabs/root ]; then
    sed '/# litefw-otlp$/d' /etc/crontabs/root >/etc/crontabs/root.lfw.tmp
  else : >/etc/crontabs/root.lfw.tmp; fi
  printf '*/5 * * * * /etc/periodic/5min/litefw-telemetry >/dev/null 2>&1 # litefw-otlp\n' >>/etc/crontabs/root.lfw.tmp
  mv /etc/crontabs/root.lfw.tmp /etc/crontabs/root
  svc_enable crond default
  svc crond restart || svc crond start || die 'Could not start cron for OTLP'
  telemetry_json >"$RESULT"
  log_op "telemetry.set prometheus=$_prom otlp=$_enabled"
}
