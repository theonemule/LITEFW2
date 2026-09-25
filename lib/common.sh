#!/bin/sh
set -eu

LITEFWM_ETC=${LITEFWM_ETC:-/etc/litefwm}
LITEFWM_INTERFACES=${LITEFWM_INTERFACES:-/etc/network/interfaces}
LITEFWM_DNSMASQ_CONF=${LITEFWM_DNSMASQ_CONF:-/etc/dnsmasq.d/litefwm.conf}
LITEFWM_LEASES=${LITEFWM_LEASES:-/var/lib/misc/dnsmasq.leases}
LITEFWM_IPTABLES_SAVE=${LITEFWM_IPTABLES_SAVE:-/etc/iptables/rules-save}
LITEFWM_LIGHTTPD_CONF=${LITEFWM_LIGHTTPD_CONF:-/etc/lighttpd/litefwm.conf}
LITEFWM_CAPTURE_DIR=${LITEFWM_CAPTURE_DIR:-/var/lib/litefwm/captures}
LITEFWM_LOG=${LITEFWM_LOG:-/var/log/litefwm}
LITEFWM_RUN=${LITEFWM_RUN:-/run/litefwm}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "This command must run as root."; }
ensure_runtime_dirs() { mkdir -p "$LITEFWM_ETC" "$LITEFWM_CAPTURE_DIR" "$LITEFWM_LOG" "$LITEFWM_RUN"; }
slug_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'; }
dev_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.:-]{1,63}$'; }
ipv4_cidr_ok() {
  printf '%s' "$1" | awk -F'[./]' '
    NF==5 && $1>=0&&$1<=255 && $2>=0&&$2<=255 && $3>=0&&$3<=255 && $4>=0&&$4<=255 && $5>=0&&$5<=32 {ok=1}
    END{exit ok?0:1}'
}
ipv4_ok() {
  printf '%s' "$1" | awk -F. '
    NF==4 && $1>=0&&$1<=255 && $2>=0&&$2<=255 && $3>=0&&$3<=255 && $4>=0&&$4<=255 {ok=1}
    END{exit ok?0:1}'
}
service_running() {
  rc-service "$1" status >/dev/null 2>&1
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
json_bool() { [ "$1" = true ] && printf true || printf false; }
