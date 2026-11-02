#!/bin/sh
# Install LiteFWM onto a dedicated Alpine Linux host and turn it into the
# appliance: LiteFWM owns networking, the firewall, dnsmasq and the web server.
# The current network configuration is kept exactly as it is running now.
set -eu
usage() {
  cat <<'TXT'
Usage: sudo ./install.sh [--port 80] [--admin-user admin] [--no-start] [--non-interactive]
       When run from a terminal, WAN/LAN appliance setup is interactive by default.
TXT
}
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = alpine ] || { echo "LiteFWM is an Alpine Linux appliance" >&2; exit 1; }
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
PORT=80; ADMIN="admin"; START=yes; INTERACTIVE=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2;;
    --admin-user) ADMIN=$2; shift 2;;
    --no-start) START=no; shift;;
    --non-interactive) INTERACTIVE=no; shift;;
    --interactive) INTERACTIVE=yes; shift;;
    -h|--help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
case "$PORT" in ''|*[!0-9]*) echo "invalid port" >&2; exit 2;; esac
printf '%s' "$ADMIN" | grep -Eq '^[A-Za-z0-9_.-]{1,32}$' || { echo "invalid admin user" >&2; exit 2; }

echo "==> packages"
apk add --no-cache ifupdown-ng iproute2 iptables dnsmasq jq lighttpd lighttpd-mod_auth \
  apache2-utils sudo busybox-openrc >/dev/null

echo "==> retiring older LiteFWM control planes (if present)"
# Older builds used either a private config store or /opt/litefwm plus nftables.
# Native service configuration for optional modules is deliberately preserved so
# v2 can adopt BIND, OpenVPN and inadyn in place.
if [ -e /etc/init.d/litefwm ] || [ -e /usr/local/sbin/fwmctl ] || [ -d /opt/litefwm ]; then
  rc-update del litefwm default >/dev/null 2>&1 || true
  rc-service litefwm stop >/dev/null 2>&1 || true
  rm -f /etc/init.d/litefwm /etc/sudoers.d/litefwm-web /etc/litefwm/config.json /etc/litefwm/config.json.tmp
  for t in apictl capturectl configctl ddnsctl dhcpctl diagctl firewallctl fwmctl logctl metricsctl \
           modulecfgctl modulectl netctl nftctl setupctl systemctl-litefwm webctl; do rm -f "/usr/local/sbin/$t"; done
  rm -rf /opt/litefwm /var/lib/litefwm /etc/litefwm/modules /usr/share/litefwm/litefwm-lighttpd.conf
  echo "    removed older LiteFWM binaries and private state"
fi
# If the previous LiteFWM nftables table exists, remove only that owned table and
# retire its boot service. v2 owns the appliance firewall with iptables.
if command -v nft >/dev/null 2>&1 && nft list table inet litefwm >/dev/null 2>&1; then
  nft delete table inet litefwm >/dev/null 2>&1 || true
  rc-update del nftables default >/dev/null 2>&1 || true
  rc-service nftables stop >/dev/null 2>&1 || true
  echo "    retired the old LiteFWM nftables table"
fi

echo "==> files"
install -d -m 0755 /usr/lib/litefwm /usr/lib/litefwm/cgi /usr/lib/litefwm/modules /usr/share/litefwm/www /etc/litefwm \
  /etc/dnsmasq.d /etc/dnsmasq.hosts.d /etc/iptables /var/lib/misc
install -m 0755 "$BASE/bin/lfwctl" /usr/sbin/lfwctl
install -m 0755 "$BASE/bin/lfw-setup" /usr/sbin/lfw-setup
install -m 0755 "$BASE/bin/litefw-web-bind" /usr/sbin/litefw-web-bind
install -m 0644 "$BASE"/lib/*.sh "$BASE"/lib/*.jq "$BASE"/lib/*.awk /usr/lib/litefwm/
install -m 0755 "$BASE/lib/udhcpc.script" /usr/lib/litefwm/udhcpc.script
rm -rf /usr/lib/litefwm/modules && cp -R "$BASE/modules" /usr/lib/litefwm/modules
find /usr/lib/litefwm/modules -type f -name '*.sh' -exec chmod 0755 {} +
install -m 0644 "$BASE/VERSION" /usr/lib/litefwm/VERSION
install -m 0755 "$BASE/cgi/api.cgi" /usr/lib/litefwm/cgi/api.cgi
rm -rf /usr/share/litefwm/www && cp -R "$BASE/www" /usr/share/litefwm/www
find /usr/share/litefwm/www -type d -exec chmod 0755 {} + ; find /usr/share/litefwm/www -type f -exec chmod 0644 {} +

echo "==> web server"
install -m 0644 "$BASE/etc/lighttpd.conf" /etc/lighttpd/lighttpd.conf
install -m 0644 "$BASE/etc/litefwm-bind.conf" /etc/lighttpd/litefwm-bind.conf
if [ -f /etc/lighttpd/litefwm.conf ]; then
  old=$(sed -n 's/^server\.port *= *\([0-9]*\).*/\1/p' /etc/lighttpd/litefwm.conf | head -n 1)
  [ -z "$old" ] || [ "$PORT" != 80 ] || PORT=$old
fi
sed "s/^server\.port = .*/server.port = $PORT/" "$BASE/etc/litefwm-lighttpd.conf" >/etc/lighttpd/litefwm.conf
mkdir -p /var/log/lighttpd && chown lighttpd:lighttpd /var/log/lighttpd
if [ ! -s /etc/litefwm/htpasswd ]; then
  PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
  printf '%s\n' "$PASS" | htpasswd -ic /etc/litefwm/htpasswd "$ADMIN" >/dev/null 2>&1
  echo "    admin login: $ADMIN / $PASS"
fi
chown root:lighttpd /etc/litefwm/htpasswd; chmod 0640 /etc/litefwm/htpasswd
/usr/sbin/litefw-web-bind
lighttpd -tt -f /etc/lighttpd/lighttpd.conf
printf 'lighttpd ALL=(root) NOPASSWD: /usr/sbin/lfwctl\nDefaults:lighttpd !requiretty, !syslog\n' >/etc/sudoers.d/litefwm
visudo -cf /etc/sudoers.d/litefwm >/dev/null
chmod 0440 /etc/sudoers.d/litefwm

echo "==> routing"
printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/90-litefwm.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "==> dnsmasq"
install -m 0644 "$BASE/etc/dnsmasq.conf" /etc/dnsmasq.conf
# the service must read exactly /etc/dnsmasq.conf (no leftover DNSMASQ_OPTS)
printf '# Owned by LiteFWM\ncfgfile="/etc/dnsmasq.conf"\nleasefile="/var/lib/misc/dnsmasq.leases"\n' >/etc/conf.d/dnsmasq
install -m 0644 "$BASE/etc/dnsmasq-base.conf" /etc/dnsmasq.d/00-litefwm.conf
[ -f /etc/dnsmasq.d/10-dns.conf ] || printf '# LiteFWM DNS settings\ndomain=lan\nlocal=/lan/\nexpand-hosts\n' >/etc/dnsmasq.d/10-dns.conf
# Adopt an existing LiteFWM BIND configuration without letting dnsmasq compete
# for port 53. DHCP stays active because port=0 disables only dnsmasq DNS.
if [ -r /etc/bind/named.conf ] && grep -q '^// LiteFWM native BIND configuration' /etc/bind/named.conf; then
  printf '%s\n' '# BIND owns port 53 while this module is configured' 'port=0' >/etc/dnsmasq.d/05-litefwm-bind.conf
fi
rm -f /etc/dnsmasq.d/litefwm/00-bind-dns.conf 2>/dev/null || true

echo "==> adopting the running network"
# Hand any interface that is currently on dhcpcd over to udhcpc, keeping its address.
for p in $(pgrep -x dhcpcd 2>/dev/null); do
  for i in /sys/class/net/*; do
    i=${i##*/}
    tr '\0' ' ' </proc/"$p"/cmdline 2>/dev/null | grep -qw "$i" || continue
    ip=$(ip -4 -o addr show dev "$i" scope global | awk '{print $4}' | head -n 1)
    kill -KILL "$p" 2>/dev/null || true
    mkdir -p /run/litefwm; : >/run/litefwm/keep."$i"
    udhcpc -b -R -p /var/run/udhcpc."$i".pid -i "$i" -s /usr/lib/litefwm/udhcpc.script ${ip:+-r ${ip%/*}} >/dev/null 2>&1 || true
  done
done
# Mark the interface holding the default route as WAN if no role is set yet.
export LFW_LIB=/usr/lib/litefwm
. /usr/lib/litefwm/common.sh; . /usr/lib/litefwm/net.sh; . /usr/lib/litefwm/fw.sh
. /usr/lib/litefwm/dhcp.sh; . /usr/lib/litefwm/sys.sh; . /usr/lib/litefwm/modules.sh
if [ -z "$(wan_iface)" ]; then
  dev=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [ -z "$dev" ] || { ip link set dev "$dev" alias "lfw:role=wan;name=WAN"; echo "    WAN segment: $dev"; }
fi
dns_listen_sync
net_persist
echo "==> firewall"
fw_snapshot
if iptables -S INPUT 2>/dev/null | grep -q -- '-j LFW_MGMT'; then fw_commit; else fw_commit any; fi

echo "==> services"
rc-update add networking boot >/dev/null 2>&1 || true
for s in iptables sysctl syslog; do rc-update add "$s" boot >/dev/null 2>&1 || true; done
for s in dnsmasq lighttpd; do rc-update add "$s" default >/dev/null 2>&1 || true; done
sed -i 's/^IPFORWARD=.*/IPFORWARD="yes"/' /etc/conf.d/iptables 2>/dev/null || true
if [ "$START" = yes ]; then
  rc-service dnsmasq restart >/dev/null 2>&1 || rc-service dnsmasq start
  rc-service lighttpd restart >/dev/null 2>&1 || rc-service lighttpd start
fi
echo
echo "LiteFWM $(cat "$BASE/VERSION") installed. Web UI: LAN interfaces only, port $PORT"
if [ "$INTERACTIVE" = auto ]; then
  if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=yes; else INTERACTIVE=no; fi
fi
if [ "$INTERACTIVE" = yes ]; then
  echo
  echo "==> appliance WAN/LAN setup"
  /usr/sbin/lfw-setup interactive
else
  echo "    Console recovery/network setup: lfw-setup"
fi