#!/bin/sh
# Installed under /etc/periodic/5min by the telemetry admin setting.
set -eu
CONF=/etc/litefwm/telemetry.json
[ -r "$CONF" ] || exit 0
[ "$(jq -r '.otlpEnabled // false' "$CONF")" = true ] || exit 0
interval=$(jq -r '.intervalMinutes // 5' "$CONF")
minute=$(date +%M | sed 's/^0*//'); [ -n "$minute" ] || minute=0
[ $((minute % interval)) -eq 0 ] || exit 0
[ -r /etc/litefwm/telemetry.curl ] || exit 0
/usr/sbin/lfwctl get telemetry-otlp |
  curl --fail --silent --show-error --max-time 15 --config /etc/litefwm/telemetry.curl --data-binary @- >/dev/null
