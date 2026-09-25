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

interface_device() {
  id=$1
  jq -er --arg id "$id" '.interfaces[] | select(.id==$id) | .device' "$LITEFWM_CONFIG"
}

segment_device() {
  id=$1
  iid=$(jq -er --arg id "$id" '.segments[] | select(.id==$id) | .interface' "$LITEFWM_CONFIG")
  interface_device "$iid"
}

segment_cidr() {
  id=$1
  jq -er --arg id "$id" '.segments[] | select(.id==$id) | .address' "$LITEFWM_CONFIG"
}

segment_ip() {
  cidr=$(segment_cidr "$1")
  printf '%s\n' "${cidr%/*}"
}

module_installed() {
  case "$1" in
    openvpn) command -v openvpn >/dev/null 2>&1;;
    tailscale) command -v tailscale >/dev/null 2>&1;;
    bind) command -v named >/dev/null 2>&1;;
    squid) command -v squid >/dev/null 2>&1;;
    snort) command -v snort >/dev/null 2>&1;;
    haproxy) command -v haproxy >/dev/null 2>&1;;
    ddns) command -v ddclient >/dev/null 2>&1;;
    *) return 1;;
  esac
}
