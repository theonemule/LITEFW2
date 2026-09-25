#!/bin/sh
# LiteFWM HTTP API (lighttpd CGI, behind HTTP basic auth).
#   GET  /api/state          live system snapshot
#   POST /api/op/NAME        apply one change; JSON body; header X-LiteFWM: 1
PATH=/usr/sbin:/usr/bin:/sbin:/bin
path=${PATH_INFO:-/state}
method=${REQUEST_METHOD:-GET}

reply() { # STATUS BODY-FILE
  printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n' "$1"
  cat "$2"
}
fail() {
  t=$(mktemp); jq -n --arg e "$2" '{ok:false,error:$e}' >"$t"; reply "$1" "$t"; rm -f "$t"; exit 0
}
ctl() { sudo -n /usr/sbin/lfwctl --client "${REMOTE_ADDR:-}" "$@"; }

out=$(mktemp); trap 'rm -f "$out" "${body:-}"' EXIT
case "$method:$path" in
  GET:/state)
    if ctl state >"$out" 2>"$out.err"; then reply '200 OK' "$out"
    else fail '500 Internal Server Error' "$(cat "$out.err")"; fi
    rm -f "$out.err"
    ;;
  POST:/op/*)
    [ "${HTTP_X_LITEFWM:-}" = 1 ] || fail '403 Forbidden' 'missing X-LiteFWM request header'
    op=${path#/op/}
    printf '%s' "$op" | grep -Eq '^[a-z]+\.[a-z]+$' || fail '404 Not Found' 'unknown operation'
    len=${CONTENT_LENGTH:-0}
    case "$len" in ''|*[!0-9]*) len=0;; esac
    [ "$len" -le 1048576 ] || fail '413 Payload Too Large' 'request too large'
    body=$(mktemp)
    head -c "$len" >"$body"
    if ctl op "$op" <"$body" >"$out" 2>/dev/null; then reply '200 OK' "$out"
    else
      [ -s "$out" ] || jq -n '{ok:false,error:"operation failed"}' >"$out"
      reply '400 Bad Request' "$out"
    fi
    ;;
  *) fail '404 Not Found' 'unknown endpoint';;
esac
