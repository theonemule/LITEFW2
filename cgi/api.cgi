#!/bin/sh
# LiteFWM resource-oriented HTTP API (lighttpd CGI, behind HTTP basic auth).
#
# Reads:
#   GET /api/identity
#   GET /api/interfaces
#   GET /api/segments
#   GET /api/firewall
#   GET /api/port-forwards
#   GET /api/dhcp
#   GET /api/dns
#   GET /api/modules
#   GET /api/modules/ID
#   GET /api/system
#
# Mutations live under the resource they change. /api/state and /api/op/NAME
# remain compatibility routes for older clients and regression tests.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
path=${PATH_INFO:-/state}
method=${REQUEST_METHOD:-GET}

reply() {
  printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n' "$1"
  cat "$2"
}
fail() {
  t=$(mktemp)
  jq -n --arg e "$2" '{ok:false,error:$e}' >"$t"
  reply "$1" "$t"
  rm -f "$t"
  exit 0
}
ctl() { sudo -n /usr/sbin/lfwctl --client "${REMOTE_ADDR:-}" "$@"; }

read_resource() {
  if ctl get "$@" >"$out" 2>"$out.err"; then
    reply '200 OK' "$out"
  else
    fail '500 Internal Server Error' "$(cat "$out.err")"
  fi
  rm -f "$out.err"
}
read_body() {
  [ "${HTTP_X_LITEFWM:-}" = 1 ] || fail '403 Forbidden' 'missing X-LiteFWM request header'
  len=${CONTENT_LENGTH:-0}
  case "$len" in ''|*[!0-9]*) len=0;; esac
  [ "$len" -le 1048576 ] || fail '413 Payload Too Large' 'request too large'
  body=$(mktemp)
  head -c "$len" >"$body"
  [ -s "$body" ] || printf '{}' >"$body"
  jq -e 'type=="object"' "$body" >/dev/null 2>&1 || fail '400 Bad Request' 'request body must be a JSON object'
}
run_op() {
  opname=$1
  printf '%s' "$opname" | grep -Eq '^[a-z]+\.[a-z]+$' || fail '404 Not Found' 'unknown operation'
  if ctl op "$opname" <"$body" >"$out" 2>/dev/null; then
    reply '200 OK' "$out"
  else
    [ -s "$out" ] || jq -n '{ok:false,error:"operation failed"}' >"$out"
    reply '400 Bad Request' "$out"
  fi
  exit 0
}
op_request() {
  read_body
  run_op "$1"
}
module_lifecycle_request() {
  mid=$1
  action=$2
  read_body
  patched=$(mktemp)
  jq --arg id "$mid" '. + {id:$id}' "$body" >"$patched"
  mv "$patched" "$body"
  run_op "module.$action"
}

out=$(mktemp)
trap 'rm -f "$out" "$out.err" "${body:-}"' EXIT

case "$method:$path" in
  GET:/identity) read_resource identity;;
  GET:/overview) read_resource overview;;
  GET:/interfaces) read_resource interfaces;;
  GET:/segments) read_resource segments;;
  GET:/firewall) read_resource firewall;;
  GET:/port-forwards) read_resource port-forwards;;
  GET:/dhcp) read_resource dhcp;;
  GET:/dns) read_resource dns;;
  GET:/modules) read_resource modules;;
  GET:/modules/*)
    mid=${path#/modules/}
    printf '%s' "$mid" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$' || fail '404 Not Found' 'unknown module endpoint'
    read_resource module "$mid"
    ;;
  GET:/system) read_resource system;;

  POST:/interfaces/iface/*)
    action=${path#/interfaces/iface/}
    case "$action" in set) op_request "iface.$action";; *) fail '404 Not Found' 'unknown interface operation';; esac
    ;;
  POST:/interfaces/bridge/*)
    action=${path#/interfaces/bridge/}
    case "$action" in create|set|delete|addmember|delmember|portvlans) op_request "bridge.$action";; *) fail '404 Not Found' 'unknown bridge operation';; esac
    ;;
  POST:/interfaces/vlan/*)
    action=${path#/interfaces/vlan/}
    case "$action" in create|delete) op_request "vlan.$action";; *) fail '404 Not Found' 'unknown VLAN operation';; esac
    ;;

  POST:/segments/set) op_request segment.set;;

  POST:/firewall/rules/*)
    action=${path#/firewall/rules/}
    case "$action" in add|update|delete|move) op_request "rule.$action";; *) fail '404 Not Found' 'unknown firewall rule operation';; esac
    ;;

  POST:/port-forwards/*)
    action=${path#/port-forwards/}
    case "$action" in add|update|delete) op_request "forward.$action";; *) fail '404 Not Found' 'unknown port-forward operation';; esac
    ;;

  POST:/dhcp/server/set) op_request dhcpd.set;;
  POST:/dhcp/reservations/add) op_request reservation.add;;
  POST:/dhcp/reservations/delete) op_request reservation.delete;;

  POST:/dns/set) op_request dns.set;;

  POST:/modules/*/*)
    rest=${path#/modules/}
    mid=${rest%%/*}
    action=${rest#*/}
    printf '%s' "$mid" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$' || fail '404 Not Found' 'unknown module endpoint'
    case "$action" in
      install|remove) module_lifecycle_request "$mid" "$action";;
      *) op_request "$mid.$action";;
    esac
    ;;

  POST:/firewall/batch) op_request firewall.batch;;
  POST:/firewall/confirm) op_request firewall.confirm;;
  POST:/system/set) op_request system.set;;
  POST:/system/management) op_request mgmt.set;;
  POST:/system/logging) op_request logging.set;;
  POST:/system/password) op_request password.set;;
  POST:/system/packages/check) op_request packages.check;;
  POST:/system/packages/upgrade) op_request packages.upgrade;;
  POST:/system/updates/check) op_request upgrade.check;;
  POST:/system/updates/install) op_request upgrade.install;;
  POST:/system/updates/upload)
    [ "${HTTP_X_LITEFWM:-}" = 1 ] || fail '403 Forbidden' 'missing X-LiteFWM request header'
    [ "${CONTENT_TYPE:-}" = application/octet-stream ] || fail '415 Unsupported Media Type' 'use application/octet-stream'
    len=${CONTENT_LENGTH:-0}
    case "$len" in ''|*[!0-9]*) fail '400 Bad Request' 'invalid upload length';; esac
    [ "$len" -gt 0 ] && [ "$len" -le 4194304 ] || fail '413 Payload Too Large' 'upgrade size must be between 1 byte and 4 MB'
    umask 077
    upload=$(mktemp /tmp/litefw-upload.XXXXXX)
    trap 'rm -f "$upload" "$out" "$out.err" "${body:-}"' EXIT
    head -c "$len" >"$upload"
    [ "$(wc -c <"$upload")" = "$len" ] || fail '400 Bad Request' 'incomplete upload'
    body=$(mktemp)
    jq -n --arg path "$upload" '{path:$path}' >"$body"
    run_op upgrade.upload
    ;;
  POST:/system/diagnostics/ping) op_request diag.ping;;
  POST:/system/diagnostics/lookup) op_request diag.lookup;;

  GET:/state)
    if ctl state >"$out" 2>"$out.err"; then
      reply '200 OK' "$out"
    else
      fail '500 Internal Server Error' "$(cat "$out.err")"
    fi
    rm -f "$out.err"
    ;;
  POST:/op/*)
    op=${path#/op/}
    op_request "$op"
    ;;
  *) fail '404 Not Found' 'unknown endpoint';;
esac