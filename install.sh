#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }
[ -r /etc/os-release ] || { echo "Unsupported host: /etc/os-release missing" >&2; exit 1; }
. /etc/os-release
[ "$ID" = alpine ] || { echo "LiteFWM currently targets Alpine Linux only." >&2; exit 1; }

BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PORT=8080
ADMIN=admin
START_WEB=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2;;
    --admin-user) ADMIN=$2; shift 2;;
    --no-start) START_WEB=false; shift;;
    -h|--help)
      cat <<'TXT'
Usage: sudo ./install.sh [--port 8080] [--admin-user admin] [--no-start]

Installs LiteFWM onto an Alpine Linux target. The installer does not create
network segments or apply custom firewall/NAT policy. Configure the appliance
through the web UI or /etc/litefwm/config.json, then apply the staged config.
TXT
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done

case "$PORT" in *[!0-9]*|'') echo "Invalid management port" >&2; exit 2;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "Invalid management port" >&2; exit 2; }
printf '%s' "$ADMIN" | grep -Eq '^[A-Za-z0-9_.-]+$' || { echo "Invalid admin user" >&2; exit 2; }

echo "Installing LiteFWM base dependencies..."
apk update
apk add --no-cache   bash jq iproute2 iptables dnsmasq tcpdump curl ca-certificates procps   lighttpd lighttpd-openrc lighttpd-mod_auth apache2-utils sudo

install -d -m 0755   /usr/local/sbin /usr/lib/litefwm /usr/lib/litefwm/cgi   /usr/share/litefwm /usr/share/litefwm/www   /etc/litefwm /var/lib/litefwm/generated /var/lib/litefwm/captures   /var/log/litefwm

install -m 0755 "$BASE"/bin/* /usr/local/sbin/
install -m 0644 "$BASE/lib/common.sh" /usr/lib/litefwm/common.sh
install -m 0755 "$BASE"/cgi/*.cgi /usr/lib/litefwm/cgi/
cp -R "$BASE"/www/. /usr/share/litefwm/www/
install -m 0644 "$BASE/lighttpd/litefwm.conf" /usr/share/litefwm/litefwm-lighttpd.conf
install -m 0755 "$BASE/openrc/litefwm" /etc/init.d/litefwm

if [ ! -r /etc/litefwm/config.json ]; then
  install -m 0640 "$BASE/etc/config.json" /etc/litefwm/config.json
fi
jq --argjson port "$PORT" '.management.port=$port' /etc/litefwm/config.json > /etc/litefwm/config.json.tmp
mv /etc/litefwm/config.json.tmp /etc/litefwm/config.json
chmod 0640 /etc/litefwm/config.json

if [ ! -s /etc/litefwm/htpasswd ]; then
  password=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 18)
  htpasswd -bc /etc/litefwm/htpasswd "$ADMIN" "$password" >/dev/null
  chmod 0640 /etc/litefwm/htpasswd
  cat <<TXT

Initial LiteFWM login
  user:     $ADMIN
  password: $password

Change it with:
  htpasswd /etc/litefwm/htpasswd $ADMIN

TXT
fi

cat > /etc/sudoers.d/litefwm-web <<'SUDOERS'
lighttpd ALL=(root) NOPASSWD: /usr/local/sbin/apictl *
SUDOERS
chmod 0440 /etc/sudoers.d/litefwm-web
visudo -cf /etc/sudoers.d/litefwm-web >/dev/null

cat > /etc/sysctl.d/90-litefwm.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
SYSCTL
sysctl -p /etc/sysctl.d/90-litefwm.conf >/dev/null || true

cat > /etc/conf.d/dnsmasq <<'DNSMASQ'
DNSMASQ_OPTS="--conf-file=/var/lib/litefwm/generated/dnsmasq.conf"
DNSMASQ

grep -q 'include "litefwm.conf"' /etc/lighttpd/lighttpd.conf 2>/dev/null || printf '\ninclude "litefwm.conf"\n' >> /etc/lighttpd/lighttpd.conf

/usr/local/sbin/configctl validate
/usr/local/sbin/webctl render >/dev/null
install -m 0644 /var/lib/litefwm/generated/lighttpd-litefwm.conf /etc/lighttpd/litefwm.conf
lighttpd -tt -f /etc/lighttpd/lighttpd.conf

rc-update add lighttpd default >/dev/null
rc-update add litefwm default >/dev/null

if [ "$START_WEB" = true ]; then
  rc-service lighttpd restart >/dev/null 2>&1 || rc-service lighttpd start
fi

cat <<TXT
LiteFWM installed on the Alpine target.

Web console:
  http://<appliance>:$PORT/

The installer has not created network segments or applied staged firewall/NAT
rules. The current configuration keeps the management port open on any
interface until you restrict management to specific segments.

Next:
  1. Sign in to the web console.
  2. Create WAN/LAN/VLAN/bridge segments.
  3. Configure DHCP, firewall rules, and NAT.
  4. Validate.
  5. Apply changes.
TXT
