#!/bin/sh
# Alpine mkimage apkovl generator. LITEFWM_SOURCE must point at this repository.
set -eu
host=${1:-litefwm}
src=${LITEFWM_SOURCE:?LITEFWM_SOURCE must point to the LiteFWM2 source tree}
[ -r "$src/VERSION" ] || { echo "invalid LITEFWM_SOURCE: $src" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

rc_add() {
  mkdir -p "$tmp/etc/runlevels/$2"
  ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"
}

install -d   "$tmp/usr/sbin" "$tmp/usr/lib/litefwm" "$tmp/usr/lib/litefwm/cgi"   "$tmp/usr/lib/litefwm/modules" "$tmp/usr/share/litefwm/www"   "$tmp/usr/local/sbin" "$tmp/etc/apk/protected_paths.d" "$tmp/etc/litefwm"   "$tmp/etc/network" "$tmp/etc/dnsmasq.d" "$tmp/etc/dnsmasq.hosts.d"   "$tmp/etc/iptables" "$tmp/etc/lighttpd" "$tmp/etc/sudoers.d"   "$tmp/etc/sysctl.d" "$tmp/etc/init.d" "$tmp/etc/conf.d"   "$tmp/var/lib/misc" "$tmp/var/log/lighttpd" "$tmp/root"

# LiteFWM CLI and runtime library.
install -m 0755 "$src/bin/lfwctl" "$tmp/usr/sbin/lfwctl"
install -m 0755 "$src/bin/lfw-setup" "$tmp/usr/sbin/lfw-setup"
install -m 0755 "$src/iso/setup-alpine-litefwm" "$tmp/usr/local/sbin/setup-alpine"

for f in "$src"/lib/*.sh "$src"/lib/*.jq "$src"/lib/*.awk; do
  [ -f "$f" ] && install -m 0644 "$f" "$tmp/usr/lib/litefwm/"
done
install -m 0755 "$src/lib/udhcpc.script" "$tmp/usr/lib/litefwm/udhcpc.script"
install -m 0644 "$src/VERSION" "$tmp/usr/lib/litefwm/VERSION"
cp -R "$src/modules/." "$tmp/usr/lib/litefwm/modules/"
find "$tmp/usr/lib/litefwm/modules" -type f -name '*.sh' -exec chmod 0755 {} +

# API and web UI are part of the installed appliance.
install -m 0755 "$src/cgi/api.cgi" "$tmp/usr/lib/litefwm/cgi/api.cgi"
cp -R "$src/www/." "$tmp/usr/share/litefwm/www/"
find "$tmp/usr/share/litefwm/www" -type d -exec chmod 0755 {} +
find "$tmp/usr/share/litefwm/www" -type f -exec chmod 0644 {} +

# Base appliance configuration.
install -m 0644 "$src/etc/dnsmasq.conf" "$tmp/etc/dnsmasq.conf"
install -m 0644 "$src/etc/dnsmasq-base.conf" "$tmp/etc/dnsmasq.d/00-litefwm.conf"
cat >"$tmp/etc/dnsmasq.d/10-dns.conf" <<'DNS'
# LiteFWM installer default
domain=lan
local=/lan/
expand-hosts
DNS
cat >"$tmp/etc/conf.d/dnsmasq" <<'DNSCONF'
# Owned by LiteFWM
cfgfile="/etc/dnsmasq.conf"
leasefile="/var/lib/misc/dnsmasq.leases"
DNSCONF

install -m 0644 "$src/etc/lighttpd.conf" "$tmp/etc/lighttpd/lighttpd.conf"
install -m 0644 "$src/etc/litefwm-lighttpd.conf" "$tmp/etc/lighttpd/litefwm.conf"
cat >"$tmp/etc/sudoers.d/litefwm" <<'SUDOERS'
lighttpd ALL=(root) NOPASSWD: /usr/sbin/lfwctl
Defaults:lighttpd !requiretty, !syslog
SUDOERS
chmod 0440 "$tmp/etc/sudoers.d/litefwm"

cat >"$tmp/etc/sysctl.d/90-litefwm.conf" <<'SYSCTL'
net.ipv4.ip_forward = 1
SYSCTL

cat >"$tmp/etc/conf.d/iptables" <<'IPTABLES'
# LiteFWM appliance firewall persistence.
IPTABLES_SAVE="/etc/iptables/rules-save"
SAVE_RESTORE_OPTIONS="-c"
SAVE_ON_STOP="yes"
IPFORWARD="yes"
IPTABLES
cat >"$tmp/etc/iptables/rules-save" <<'RULES'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT
RULES

# Generate a unique UI credential on first boot. The live installer creates it
# before setup-disk packages the overlay, so it is preserved into that install.
cat >"$tmp/etc/init.d/litefwm-init" <<'INIT'
#!/sbin/openrc-run
description="Initialize LiteFWM appliance runtime"

depend() {
  need localmount
  before lighttpd
}

start() {
  ebegin "Initializing LiteFWM"
  install -d -m 0755 /etc/litefwm /var/log/lighttpd
  chown lighttpd:lighttpd /var/log/lighttpd 2>/dev/null || true

  if [ ! -s /etc/litefwm/htpasswd ]; then
    umask 077
    pass=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    printf '%s
' "$pass" | htpasswd -ic /etc/litefwm/htpasswd admin >/dev/null 2>&1
    cat >/root/litefwm-admin.txt <<EOF_CRED
LiteFWM management UI
User: admin
Password: $pass
EOF_CRED
    chmod 0600 /root/litefwm-admin.txt
    printf '
LiteFWM UI credentials written to /root/litefwm-admin.txt
' >/dev/console 2>/dev/null || true
  fi
  chown root:lighttpd /etc/litefwm/htpasswd 2>/dev/null || true
  chmod 0640 /etc/litefwm/htpasswd 2>/dev/null || true
  eend 0
}
INIT
chmod 0755 "$tmp/etc/init.d/litefwm-init"

# Installed base appliance only. Optional module APKs are on the ISO repository
# but deliberately not installed by default.
cat >"$tmp/etc/apk/world" <<'WORLD'
alpine-base
alpine-conf
ifupdown-ng
iproute2
iptables
dnsmasq
jq
util-linux
openssh
lighttpd
lighttpd-mod_auth
apache2-utils
sudo
busybox-openrc
WORLD

# lbu carries /etc automatically, but custom application/UI files under /usr
# must be explicitly protected for Alpine sys-mode setup-disk.
{
  [ ! -f "$tmp/usr/sbin/lfwctl" ] || printf '%s\n' "$tmp/usr/sbin/lfwctl"
  [ ! -f "$tmp/usr/sbin/lfw-setup" ] || printf '%s\n' "$tmp/usr/sbin/lfw-setup"
  find "$tmp/usr/lib/litefwm" -type f -print
  find "$tmp/usr/share/litefwm" -type f -print
  printf '%s\n' \
    "$tmp/etc/init.d/litefwm-init" \
    "$tmp/etc/sudoers.d/litefwm" \
    "$tmp/etc/sysctl.d/90-litefwm.conf" \
    "$tmp/etc/conf.d/dnsmasq" \
    "$tmp/etc/conf.d/iptables" \
    "$tmp/etc/lighttpd/lighttpd.conf" \
    "$tmp/etc/lighttpd/litefwm.conf" \
    "$tmp/etc/dnsmasq.conf" \
    "$tmp/etc/dnsmasq.d/00-litefwm.conf" \
    "$tmp/etc/dnsmasq.d/10-dns.conf" \
    "$tmp/etc/iptables/rules-save" \
    "$tmp/etc/litefwm/htpasswd" \
    "$tmp/root/litefwm-admin.txt"
} | sed "s#^$tmp/#+#" >"$tmp/etc/apk/protected_paths.d/lbu.list"

# Normal Alpine live-media services plus installed appliance services.
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit
rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot
rc_add iptables boot
rc_add litefwm-init boot
rc_add dnsmasq default
rc_add lighttpd default
rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

cat >"$tmp/etc/motd" <<'MOTD'
LiteFWM appliance installer

Run: setup-alpine

The normal Alpine setup runs first. Immediately before Disk & Install, LiteFWM
asks which interface is the WAN / Internet edge and which is the LAN / internal
network. The stock Alpine installer remains available as /sbin/setup-alpine.

Management credentials are generated per appliance and written to:
  /root/litefwm-admin.txt
MOTD

tar -c -C "$tmp" . | gzip -9n >"${host}.apkovl.tar.gz"
