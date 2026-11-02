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
for command in litefw-admin litefw-network litefw-console litefw-web-bind litefw-ssh-access litefw-upgrade; do
  install -m 0755 "$src/bin/$command" "$tmp/usr/sbin/$command"
done
install -m 0755 "$src/iso/setup-alpine-litefwm" "$tmp/usr/local/sbin/setup-alpine"
# Replace the Alpine installer command itself, not only the menu shortcut.
install -m 0755 "$src/iso/setup-alpine-litefwm" "$tmp/usr/sbin/setup-alpine"

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
# Boot the installer with no automatic DHCP on any NIC.
cat >"$tmp/etc/network/interfaces" <<'NET'
auto lo
iface lo inet loopback
NET

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
install -m 0644 "$src/etc/litefwm-bind.conf" "$tmp/etc/lighttpd/litefwm-bind.conf"
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

# Initialize runtime; never generate credentials or write a plaintext password.
cat >"$tmp/etc/init.d/litefwm-init" <<'INIT'
#!/sbin/openrc-run
description="Initialize LiteFW appliance runtime"

depend() {
  need localmount
  before lighttpd
}

start() {
  ebegin "Initializing LiteFW"
  install -d -m 0755 /etc/litefwm /var/log/lighttpd
  # Alpine installs alpine-conf after apkovl extraction, which can overwrite
  # /usr/sbin/setup-alpine with the stock account/network wizard. Restore the
  # real LiteFW installer AFTER packages finish loading, on every boot.
  if ! install -m 0755 /usr/local/sbin/setup-alpine /usr/sbin/setup-alpine; then
    eerror "Could not activate LiteFW installation wizard"
    eend 1
    return 1
  fi
  # Revoke any temporary root SSH password access at boot for recovery safety.
  # The console menu can also revoke it instantly, with no reboot.
  rm -f /etc/ssh/sshd_config.d/00-litefw-temporary-root.conf
  # Set the root password to empty at runtime, after the image is booted.
  # The VGA getty is configured to bypass login authentication entirely,
  # so it does not depend on timing of this operation.
  passwd -d root >/dev/null 2>&1 || {
    eerror "Unable to clear root console password"
    eend 1
    return 1
  }
  # Alpine's initramfs appends a new getty on the kernel's console=tty0
  # AFTER the apkovl inittab is loaded. That getty steals the VGA console
  # and prompts for a password even when tty1 already has a root shell.
  # Remove it on each boot and reload BusyBox init so the getty is killed.
  if grep -q '^tty0::respawn:' /etc/inittab; then
    sed -i '/^tty0::respawn:/d' /etc/inittab || {
      eerror "Unable to remove unexpected VGA login prompt"
      eend 1
      return 1
    }
    kill -HUP 1 || {
      eerror "Unable to reload VGA console configuration"
      eend 1
      return 1
    }
  fi
  chvt 1 >/dev/null 2>&1 || true
  if ! /usr/sbin/litefw-web-bind; then
    eerror "Could not restrict web listener to LAN addresses"
    eend 1
    return 1
  fi
  chown lighttpd:lighttpd /var/log/lighttpd 2>/dev/null || true
  if [ ! -s /etc/litefwm/htpasswd ]; then
    einfo "Web UI is not configured yet. Open the LiteFW console to configure it."
    eend 0
    return 0
  fi
  chown root:lighttpd /etc/litefwm/htpasswd
  chmod 0640 /etc/litefwm/htpasswd
  eend 0
}
INIT
chmod 0755 "$tmp/etc/init.d/litefwm-init"

# Default SSH root login is key-only. The local console can temporarily
# allow a root SSH password, then reverse the change immediately.
install -d "$tmp/etc/ssh/sshd_config.d"
cat >"$tmp/etc/ssh/sshd_config.d/90-litefwm-console-only.conf" <<'SSHD'
PermitRootLogin prohibit-password
PermitEmptyPasswords no
SSHD

# Configure the actual boot-time login files in the image, not via a service
# which may start after the console gettys are already accepting logins.
# A local/Proxmox console is administrator-controlled; SSH never accepts an
# empty root password (sshd_config above).
# The image builder is unprivileged and cannot read the builder's shadow
# database; the root password is cleared on boot (see litefwm-init above).

# Alpine's BusyBox getty normally starts /bin/login, which prompted on VGA
# even after the later boot-service password reset. Start authenticated root
# directly at the *local* virtual terminals instead.
cat >"$tmp/usr/local/sbin/litefw2-console-login" <<'CONSOLE'
#!/bin/sh
exec /bin/login -f root
CONSOLE
chmod 0755 "$tmp/usr/local/sbin/litefw2-console-login"
cp /etc/inittab "$tmp/etc/inittab"
# tty1 opens the LiteFW appliance console rather than an Alpine login shell.
sed -i 's#^tty1::respawn:/sbin/getty .*#tty1::respawn:/usr/sbin/litefw-console#' "$tmp/etc/inittab"
# Other local VTs use the usual autologin adapter for console recovery.
sed -i '/^tty[2-6]::respawn:\/sbin\/getty / s#:/sbin/getty #:/sbin/getty -n -l /usr/local/sbin/litefw2-console-login #' "$tmp/etc/inittab"
grep -qx 'tty1::respawn:/usr/sbin/litefw-console' "$tmp/etc/inittab"

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
  for command in litefw-admin litefw-network litefw-console litefw-web-bind litefw-ssh-access litefw-upgrade; do
    printf '%s\n' "$tmp/usr/sbin/$command"
  done
  printf '%s\n' "$tmp/usr/local/sbin/litefw2-console-login"
  printf '%s\n' "$tmp/usr/sbin/setup-alpine" "$tmp/usr/local/sbin/setup-alpine"
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
    "$tmp/etc/lighttpd/litefwm-bind.conf" \
    "$tmp/etc/dnsmasq.conf" \
    "$tmp/etc/dnsmasq.d/00-litefwm.conf" \
    "$tmp/etc/dnsmasq.d/10-dns.conf" \
    "$tmp/etc/iptables/rules-save" \
    "$tmp/etc/litefwm/htpasswd" \
    "$tmp/etc/inittab" \
    "$tmp/etc/ssh/sshd_config.d/90-litefwm-console-only.conf"
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
rc_add sshd default
rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

cat >"$tmp/etc/motd" <<MOTD
LiteFW $(cat "$src/VERSION") - Firewall & Network Appliance

Local VGA: automatic LiteFW management menu (no root password prompt).
On the live ISO use option 1 to install LiteFW. Disk installations have no
installer option. Web management binds only to LAN addresses.
SSH is installed automatically.
Temporary root SSH can be enabled and disabled from the console menu.
MOTD
cat >"$tmp/etc/issue" <<ISSUE
LiteFW $(cat "$src/VERSION") - Firewall & Network Appliance
ISSUE

tar -c -C "$tmp" . | gzip -9n >"${host}.apkovl.tar.gz"