# shellcheck shell=sh
# Compatibility helpers for self-contained optional module controllers.
require_root(){ [ "$(id -u)" -eq 0 ] || die "Root required"; }
safe_iface(){ is_ifname "$1"; }
valid_ipv4(){ is_ipv4 "$1"; }
valid_cidr(){ is_cidr "$1"; }
valid_port(){ is_port "$1"; }
valid_dns_name(){
  _v=${1:-}
  [ -z "$_v" ] && return 0
  [ "${#_v}" -le 253 ] || return 1
  printf '%s' "$_v" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
}
valid_ipv4_csv(){
  [ -z "${1:-}" ] && return 0
  _oldifs=$IFS; IFS=,
  for _x in $1; do valid_ipv4 "$_x" || { IFS=$_oldifs; return 1; }; done
  IFS=$_oldifs
}
