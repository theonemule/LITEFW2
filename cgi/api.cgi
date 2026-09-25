#!/bin/sh
set -u

json_header() {
  printf 'Content-Type: application/json\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
}
fail() {
  code=$1; shift
  printf 'Status: %s\r\n' "$code"
  json_header
  jq -n --arg error "$*" '{ok:false,error:$error}'
  exit 0
}
mutating_guard() {
  guard=$(printenv HTTP_X_LITEFWM_REQUEST 2>/dev/null || true)
  [ "$guard" = 1 ] || fail '403 Forbidden' 'Missing request guard header'
}
run_priv() {
  if command -v sudo >/dev/null 2>&1; then sudo -n /usr/local/sbin/apictl "$@"; else /usr/local/sbin/apictl "$@"; fi
}
run_json() {
  error_code=$1; shift
  out=$(mktemp); err=$(mktemp)
  if run_priv "$@" >"$out" 2>"$err"; then
    json_header; cat "$out"; rm -f "$out" "$err"; return 0
  fi
  msg=$(cat "$err"); [ -n "$msg" ] || msg=$(cat "$out")
  rm -f "$out" "$err"; fail "$error_code" "$msg"
}
run_json_stdin() {
  error_code=$1; body_file=$2; shift 2
  out=$(mktemp); err=$(mktemp)
  if run_priv "$@" <"$body_file" >"$out" 2>"$err"; then
    json_header; cat "$out"; rm -f "$out" "$err"; return 0
  fi
  msg=$(cat "$err"); [ -n "$msg" ] || msg=$(cat "$out")
  rm -f "$out" "$err"; fail "$error_code" "$msg"
}
read_body() {
  len=$(printenv CONTENT_LENGTH 2>/dev/null || echo 0)
  case "$len" in *[!0-9]*|'') len=0;; esac
  [ "$len" -le 1048576 ] || fail '413 Payload Too Large' 'Request body exceeds 1 MiB'
  dd bs=1 count="$len" 2>/dev/null
}
path=$(printenv PATH_INFO 2>/dev/null || echo /status)
method=$(printenv REQUEST_METHOD 2>/dev/null || echo GET)
[ -n "$path" ] || path=/status

case "$method:$path" in
  GET:/status) run_json '500 Internal Server Error' status;;
  GET:/config) run_json '500 Internal Server Error' config-get;;
  GET:/interfaces) run_json '500 Internal Server Error' interfaces;;
  GET:/leases) run_json '500 Internal Server Error' leases;;
  GET:/modules) run_json '500 Internal Server Error' modules;;
  GET:/metrics) run_json '500 Internal Server Error' metrics;;
  GET:/captures) run_json '500 Internal Server Error' captures;;
  GET:/logs/firewall) run_json '500 Internal Server Error' logs firewall 200;;
  GET:/logs/system) run_json '500 Internal Server Error' logs system 200;;
  GET:/ddns) run_json '500 Internal Server Error' module-get ddns;;
  GET:/ddns/status) run_json '500 Internal Server Error' module-status ddns;;
  GET:/module/config/*)
    mod=${path##*/}; run_json '500 Internal Server Error' module-get "$mod";;
  GET:/module/status/*)
    mod=${path##*/}; run_json '500 Internal Server Error' module-status "$mod";;

  PUT:/config)
    mutating_guard; tmp=$(mktemp); read_body > "$tmp"
    run_json_stdin '400 Bad Request' "$tmp" config-set; rm -f "$tmp";;
  PUT:/ddns)
    mutating_guard; tmp=$(mktemp); read_body > "$tmp"
    run_json_stdin '400 Bad Request' "$tmp" module-set ddns; rm -f "$tmp";;
  PUT:/module/config/*)
    mutating_guard; mod=${path##*/}; tmp=$(mktemp); read_body > "$tmp"
    run_json_stdin '400 Bad Request' "$tmp" module-set "$mod"; rm -f "$tmp";;
  POST:/validate) mutating_guard; run_json '400 Bad Request' validate;;
  POST:/apply) mutating_guard; run_json '400 Bad Request' apply;;
  POST:/rollback) mutating_guard; run_json '400 Bad Request' rollback;;
  POST:/reserve)
    mutating_guard; body=$(read_body)
    seg=$(printf '%s' "$body" | jq -r '.segment // ""')
    mac=$(printf '%s' "$body" | jq -r .mac)
    host=$(printf '%s' "$body" | jq -r '.hostname // ""')
    publish=$(printf '%s' "$body" | jq -r '.publishDns // false')
    run_json '400 Bad Request' reserve "$seg" "$mac" "$host" "$publish"
    ;;
  POST:/module/install)
    mutating_guard; body=$(read_body); mod=$(printf '%s' "$body" | jq -r .module)
    run_json '400 Bad Request' module-install "$mod";;
  POST:/module/remove)
    mutating_guard; body=$(read_body); mod=$(printf '%s' "$body" | jq -r .module)
    run_json '400 Bad Request' module-remove "$mod";;
  POST:/module/apply/*)
    mutating_guard; mod=${path##*/}; run_json '400 Bad Request' module-apply "$mod";;
  POST:/ddns/apply) mutating_guard; run_json '400 Bad Request' module-apply ddns;;
  POST:/ddns/query) mutating_guard; run_json '400 Bad Request' ddns-query;;
  POST:/capture)
    mutating_guard; body=$(read_body); seg=$(printf '%s' "$body"|jq -r .segment); seconds=$(printf '%s' "$body"|jq -r '.seconds // 30')
    run_json '400 Bad Request' capture-start "$seg" "$seconds";;
  POST:/capture/delete)
    mutating_guard; body=$(read_body); name=$(printf '%s' "$body"|jq -r .name)
    run_json '400 Bad Request' capture-delete "$name";;
  POST:/diag/lookup)
    mutating_guard; body=$(read_body); host=$(printf '%s' "$body"|jq -r .host); server=$(printf '%s' "$body"|jq -r '.server // ""')
    run_json '400 Bad Request' diag-lookup "$host" "$server";;
  POST:/diag/ping)
    mutating_guard; body=$(read_body); host=$(printf '%s' "$body"|jq -r .host)
    run_json '400 Bad Request' diag-ping "$host";;
  POST:/diag/route)
    mutating_guard; body=$(read_body); host=$(printf '%s' "$body"|jq -r .host)
    run_json '400 Bad Request' diag-route "$host";;
  *) fail '404 Not Found' 'Unknown API endpoint';;
esac
