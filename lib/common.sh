#!/bin/sh
set -eu

LITEFWM_ETC=$(printenv LITEFWM_ETC 2>/dev/null || echo /etc/litefwm)
LITEFWM_CONFIG=$(printenv LITEFWM_CONFIG 2>/dev/null || echo "$LITEFWM_ETC/config.json")
LITEFWM_STATE=$(printenv LITEFWM_STATE 2>/dev/null || echo /var/lib/litefwm)
LITEFWM_RUN=$(printenv LITEFWM_RUN 2>/dev/null || echo /run/litefwm)
LITEFWM_LOG=$(printenv LITEFWM_LOG 2>/dev/null || echo /var/log/litefwm)
LITEFWM_GENERATED=$(printenv LITEFWM_GENERATED 2>/dev/null || echo "$LITEFWM_STATE/generated")

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "This command must run as root."; }
ensure_dirs() { mkdir -p "$LITEFWM_ETC" "$LITEFWM_STATE" "$LITEFWM_RUN" "$LITEFWM_LOG" "$LITEFWM_GENERATED"; }
config_exists() { [ -r "$LITEFWM_CONFIG" ] || die "Missing configuration: $LITEFWM_CONFIG"; }
slug_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'; }

segment_device() {
  id=$1
  jq -er --arg id "$id" '
    .segments[] | select(.id==$id) |
    if .type=="interface" then .interface
    elif .type=="bridge" then .bridge
    elif .type=="vlan" then (.device // (.parent + "." + (.vlanId|tostring)))
    else empty end
  ' "$LITEFWM_CONFIG"
}
