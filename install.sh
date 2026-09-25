#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }
[ -r /etc/os-release ] || { echo "Unsupported host: /etc/os-release missing" >&2; exit 1; }
. /etc/os-release
[ "$ID" = alpine ] || { echo "LiteFWM currently targets Alpine Linux only." >&2; exit 1; }

BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PORT=5187
ADMIN=admin
START_WEB=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2;;
    --admin-user) ADMIN=$2; shift 2;;
    --no-start) START_WEB=false; shift;;
    -h|--help)
      cat <<'TXT'
Usage: sudo ./install.sh [--port 5187] [--admin-user admin] [--no-start]

Installs LiteFWM onto an Alpine Linux target. LiteFWM reads the running Linux
network/firewall/service state directly. Changes made in the UI are applied
immediately and persisted to the native Alpine/service configuration files.
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

install -d -m 0755   /usr/local/sbin /usr/lib/litefwm /usr/lib/litefwm/cgi   /usr/share/litefwm /usr/share/litefwm/www   /etc/litefwm /var/lib/litefwm/captures /var/log/litefwm

install -m 0755 "$BASE"/bin/* /usr/local/sbin/
install -m 0644 "$BASE/lib/common.sh" /usr/lib/litefwm/common.sh
install -m 0755 "$BASE"/cgi/*.cgi /usr/lib/litefwm/cgi/
cp -R "$BASE"/www/. /usr/share/litefwm/www/
install -m 0644 "$BASE/lighttpd/litefwm.conf" /usr/share/litefwm/litefwm-lighttpd.conf

# Remove every artifact from the retired staged/declarative configuration model.
rc-service litefwm stop >/dev/null 2>&1 || true
rc-update del litefwm default >/dev/null 2>&1 || true
rm -f   /etc/init.d/litefwm   /etc/litefwm/config.json /etc/litefwm/config.json.tmp   /var/lib/litefwm/config.previous.json /var/lib/litefwm/last-apply   /var/lib/litefwm/applied-interfaces.json /var/lib/litefwm/applied-segments.json   2>/dev/null || true
rm -rf /var/lib/litefwm/generated /etc/litefwm/modules 2>/dev/null || true

if [ ! -s /etc/litefwm/htpasswd ]; then
  password=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 18)
  htpasswd -bc /etc/litefwm/htpasswd "$ADMIN" "$password" >/dev/null
  chown root:lighttpd /etc/litefwm/htpasswd
  chmod 0640 /etc/litefwm/htpasswd
  cat <<TXT

Initial LiteFWM login
  user:     $ADMIN
  password: $password

Change it with:
  htpasswd /etc/litefwm/htpasswd $ADMIN

TXT
fi
chown root:lighttpd /etc/litefwm/htpasswd
chmod 0640 /etc/litefwm/htpasswd

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

mkdir -p /etc/dnsmasq.d
cat > /etc/conf.d/dnsmasq <<'DNSMASQ'
DNSMASQ_OPTS="--conf-file=/etc/dnsmasq.d/litefwm.conf"
DNSMASQ

# Alpine's stock lighttpd.conf already defines server.document-root. Update
# that single global value instead of redefining it in the LiteFWM include,
# which Lighttpd rejects as a duplicate global variable.
if grep -Eq '^[[:space:]]*server[.]document-root[[:space:]]*=' /etc/lighttpd/lighttpd.conf; then
  sed -i 's|^[[:space:]]*server[.]document-root[[:space:]]*=.*|server.document-root = "/usr/share/litefwm/www"|' /etc/lighttpd/lighttpd.conf
else
  printf '\nserver.document-root = "/usr/share/litefwm/www"\n' >> /etc/lighttpd/lighttpd.conf
fi

grep -q 'include "litefwm.conf"' /etc/lighttpd/lighttpd.conf 2>/dev/null || printf '\ninclude "litefwm.conf"\n' >> /etc/lighttpd/lighttpd.conf

tmp_web=$(mktemp)
jq -n --arg hostname "$(hostname)" --argjson port "$PORT" '{hostname:$hostname,management:{port:$port,sshPort:22,allowSsh:true,allowAny:true,allowedSegments:[]}}' > "$tmp_web"
/usr/local/sbin/webctl reconcile "$tmp_web"
rm -f "$tmp_web"
lighttpd -tt -f /etc/lighttpd/lighttpd.conf

rc-update add lighttpd default >/dev/null

if [ "$START_WEB" = true ]; then
  rc-service lighttpd restart >/dev/null 2>&1 || rc-service lighttpd start
fi

cat <<TXT
LiteFWM installed on the Alpine target.

Web console:
  http://<appliance>:$PORT/

LiteFWM is live-state based. It reads the current Linux network, routes,
iptables, DHCP, and service state directly. UI changes take effect immediately
and are persisted in native Alpine/service configuration.

Next:
  1. Sign in to the web console.
  2. Configure physical, bridge, and VLAN interfaces as needed.
  3. Configure interface IP/DHCP settings.
  4. Configure firewall rules and NAT.
TXT
