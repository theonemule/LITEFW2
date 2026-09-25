# shellcheck shell=sh
# LiteFWM common helpers. Sourced by lfwctl; never executed directly.
#
# Design rule: nothing in LiteFWM keeps its own copy of configuration.
# Every read comes from the kernel or from the native service file, and every
# write goes to the kernel first and is then serialised to the native boot file.

: "${LFW_LIB:=/usr/lib/litefwm}"
: "${LFW_RUN:=/run/litefwm}"
: "${LFW_LOG:=/var/log/litefwm.log}"
: "${LFW_IFACES:=/etc/network/interfaces}"
: "${LFW_DNSMASQ_CONF:=/etc/dnsmasq.conf}"
: "${LFW_DNSMASQ_DIR:=/etc/dnsmasq.d}"
: "${LFW_HOSTS_DIR:=/etc/dnsmasq.hosts.d}"
: "${LFW_LEASES:=/var/lib/misc/dnsmasq.leases}"
: "${LFW_FW_SAVE:=/etc/iptables/rules-save}"
: "${LFW_LIGHTTPD_CONF:=/etc/lighttpd/litefwm.conf}"
: "${LFW_HTPASSWD:=/etc/litefwm/htpasswd}"
: "${LFW_SSHD_CONF:=/etc/ssh/sshd_config}"
: "${LFW_UDHCPC_SCRIPT:=$LFW_LIB/udhcpc.script}"

WARNINGS=""

die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { WARNINGS="${WARNINGS}${WARNINGS:+
}$*"; }
log_op() {
  printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${LFW_CLIENT:-cli}" "$*" >>"$LFW_LOG" 2>/dev/null || true
}

# run CMD... : run a command, abort the operation with its stderr on failure.
run() {
  local _err
  if ! _err=$("$@" 2>&1 >/dev/null); then
    die "$* failed: $_err"
  fi
}
# try CMD... : run a command, ignore failure.
try() { "$@" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- validation
is_ifname() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*|.*|-*) return 1;; esac
  [ "${#1}" -le 15 ]
}
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "${#1}" -le 10 ]; }
is_ipv4() {
  printf '%s' "$1" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++) if($i!~/^[0-9]{1,3}$/ || $i+0>255) exit 1}'
}
is_cidr() {
  case "$1" in */*) :;; *) return 1;; esac
  is_ipv4 "${1%/*}" && is_uint "${1#*/}" && [ "${1#*/}" -le 32 ]
}
# address: bare IPv4 or CIDR
is_addr() { is_ipv4 "$1" || is_cidr "$1"; }
is_mac() {
  printf '%s' "$1" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
}
is_port() { is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
# ports: 80 | 8000-8100 | 80,443,8000-8100 (max 15 elements)
is_ports() {
  local _n _p
  _n=0
  for _p in $(printf '%s' "$1" | tr ',' ' '); do
    _n=$((_n + 1))
    case "$_p" in
      *-*) is_port "${_p%-*}" && is_port "${_p#*-}" && [ "${_p%-*}" -le "${_p#*-}" ] || return 1;;
      *) is_port "$_p" || return 1;;
    esac
  done
  [ "$_n" -ge 1 ] && [ "$_n" -le 15 ]
}
is_hostname() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'; }
is_fqdn() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'; }
is_label() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,31}$'; }
is_desc() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9 _.,:/()+#@-]{0,64}$'; }
is_lease_time() { printf '%s' "$1" | grep -Eq '^([0-9]{1,7}[smhdw]?|infinite)$'; }

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# ---------------------------------------------------------------- IPv4 math
ip2int() { printf '%s' "$1" | awk -F. '{printf "%.0f", (($1*256+$2)*256+$3)*256+$4}'; }
int2ip() { awk -v n="$1" 'BEGIN{printf "%d.%d.%d.%d", int(n/16777216)%256, int(n/65536)%256, int(n/256)%256, n%256}'; }
# cidr_net 192.168.1.7/24 -> 192.168.1.0
cidr_net() {
  awk -v a="${1%/*}" -v p="${1#*/}" 'BEGIN{split(a,o,".");n=((o[1]*256+o[2])*256+o[3])*256+o[4];
    s=2^(32-p); n=int(n/s)*s; printf "%d.%d.%d.%d", int(n/16777216)%256, int(n/65536)%256, int(n/256)%256, n%256}'
}
cidr_mask() {
  awk -v p="$1" 'BEGIN{n=2^32-2^(32-p); printf "%d.%d.%d.%d", int(n/16777216)%256, int(n/65536)%256, int(n/256)%256, n%256}'
}
# in_cidr IP CIDR
in_cidr() {
  awk -v a="$1" -v c="$2" 'BEGIN{split(c,x,"/"); p=x[2];
    split(a,o,"."); n=((o[1]*256+o[2])*256+o[3])*256+o[4];
    split(x[1],q,"."); m=((q[1]*256+q[2])*256+q[3])*256+q[4];
    s=2^(32-p); exit !(int(n/s)==int(m/s))}'
}

# ---------------------------------------------------------------- request body
# The request body (JSON) is in $BODY. These helpers read single fields.
jget() { jq -r --arg k "$1" 'if (.[$k]? // null) == null then empty else .[$k] | tostring end' "$BODY"; }
jhas() { jq -e --arg k "$1" 'has($k)' "$BODY" >/dev/null 2>&1; }
jlist() { jq -r --arg k "$1" '(.[$k]? // []) | if type=="array" then .[] | tostring else tostring end' "$BODY"; }
jbool() { [ "$(jget "$1")" = true ]; }

# ---------------------------------------------------------------- services
svc() { # svc NAME ACTION
  if command -v rc-service >/dev/null 2>&1; then
    # 9>&- : never let a daemon inherit the operation lock
    rc-service "$1" "$2" >/dev/null 2>&1 9>&-
  else
    return 1
  fi
}
svc_enable() { rc-update add "$1" "${2:-default}" >/dev/null 2>&1 9>&- || true; }
