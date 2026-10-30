#!/bin/sh
# Execute the single LiteFW2 setup-alpine command with a mock Alpine disk step.
# Validate the real Alpine installer's stable injection point separately.
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD/iso/setup-alpine-litefwm:/usr/local/sbin/setup-alpine:ro" alpine:3.24 sh -euc '
  apk add --quiet --no-cache alpine-conf apache2-utils lighttpd >/dev/null
  test -x /usr/sbin/setup-alpine
  grep -q '\''^print_heading2 " Disk & Install"$'\'' /usr/sbin/setup-alpine
  # Replace the real Alpine interactive workflow with a minimal disk handoff
  # to isolate and execute the inserted firewall + credential stages.
  cat >/usr/sbin/setup-alpine <<\MOCK
#!/bin/sh
print_heading2() { echo "$1"; }
print_heading2 " Disk & Install"
echo ALPINE_DISK_INSTALL_REACHED
MOCK
  chmod +x /usr/sbin/setup-alpine
  cat >/usr/sbin/lfw-setup <<\MOCK
#!/bin/sh
[ "$1" = interactive ] || exit 1
echo firewall-configured > /tmp/fw-configured
MOCK
  chmod +x /usr/sbin/lfw-setup
  printf "SmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" | /usr/local/sbin/setup-alpine >/tmp/installer.log 2>&1 || { cat /tmp/installer.log; exit 1; }
  grep -q "ALPINE_DISK_INSTALL_REACHED" /tmp/installer.log
  test -s /tmp/fw-configured
  test -s /etc/litefwm/htpasswd
  htpasswd -vb /etc/litefwm/htpasswd admin "SmokeTestOnlyPassword123!" >/dev/null
  test ! -e /root/litefwm-admin.txt
  ! grep -q "SmokeTestOnlyPassword123!" /tmp/installer.log
  echo "PASS single setup-alpine command invoked firewall configuration, securely set web admin password, and reached disk install"
'
