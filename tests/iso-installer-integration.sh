#!/bin/sh
# Validate the real Alpine integration points and the LiteFW2 network behavior.
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD/iso/setup-alpine-litefwm:/usr/local/sbin/setup-alpine:ro" alpine:3.24 sh -euc '
  apk add --quiet --no-cache alpine-conf apache2-utils lighttpd jq iproute2 >/dev/null
  # Abort if Alpine changes the stock markers rather than silently falling back
  # to its potentially unbounded setup-interfaces DHCP step.
  grep -qx "# set Interface" /usr/sbin/setup-alpine
  grep -q "^print_heading2 \" Disk & Install\"$" /usr/sbin/setup-alpine
  cat >/usr/sbin/setup-alpine <<\MOCK
#!/bin/sh
[ "$1" = "-e" ] || { echo "root password suppression missing" >&2; exit 1; }
print_heading2() { echo "$1"; }
# set Interface
echo STOCK_NETWORK_WAS_CALLED
setup-interfaces -r
setup-dns
# set root password
echo ROOT_PASSWORD_SECTION_PASSED
print_heading2 " Disk & Install"
echo ALPINE_DISK_INSTALL_REACHED
MOCK
  chmod +x /usr/sbin/setup-alpine
  cat >/usr/sbin/setup-interfaces <<\MOCK
#!/bin/sh
echo "STOCK_NETWORK_WAS_CALLED" >&2
exit 1
MOCK
  chmod +x /usr/sbin/setup-interfaces
  cat >/usr/sbin/lfw-setup <<\MOCK
#!/bin/sh
echo "lfw-setup not used for initial installation" >&2
exit 1
MOCK
  chmod +x /usr/sbin/lfw-setup
  cat >/usr/sbin/lfwctl <<\MOCK
#!/bin/sh
[ "$1" = op ] && [ "$2" = segment.set ] || exit 1
printf "%s\n" "$3" >>/tmp/segment-ops
printf "{\"ok\":true}\n"
MOCK
  chmod +x /usr/sbin/lfwctl
  mkdir -p /usr/local/bin
  # Simulate DHCP timeout without relying on a real DHCP server.
  cat >/usr/local/bin/ip <<\MOCK
#!/bin/sh
[ "$1" = -4 ] && [ "$2" = -o ] && exit 0
exec /sbin/ip "$@"
MOCK
  chmod +x /usr/local/bin/ip
  test -e /sys/class/net/eth0

  # Single-NIC firewall: DHCP fails, operator continues offline.
  # This must finish without Alpine setup-interfaces being called.
  printf "\n\n\nnone\nnone\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 30 /usr/local/sbin/setup-alpine >/tmp/installer.log 2>&1 \
    || { cat /tmp/installer.log; exit 1; }
  grep -q "DHCP timed out" /tmp/installer.log
  grep -q "ALPINE_DISK_INSTALL_REACHED" /tmp/installer.log
  ! grep -q "STOCK_NETWORK_WAS_CALLED" /tmp/installer.log
  grep -q "\"role\":\"wan\".*\"mode\":\"dhcp\"" /tmp/segment-ops
  grep -q "\"role\":\"wan\".*\"mode\":\"none\"" /tmp/segment-ops
  test -s /etc/litefwm/htpasswd
  htpasswd -vb /etc/litefwm/htpasswd admin "SmokeTestOnlyPassword123!" >/dev/null
  ! grep -q "SmokeTestOnlyPassword123!" /tmp/installer.log
  echo "PASS DHCP timeout and offline fallback; stock Alpine networking bypassed"

  # The static WAN alternative must pass CIDR/gateway/DNS to LiteFW2.
  rm -f /tmp/segment-ops /etc/litefwm/htpasswd
  printf "\nstatic\n192.168.50.2/24\n192.168.50.1\n9.9.9.9\nnone\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 15 /usr/local/sbin/setup-alpine >/tmp/installer-static.log 2>&1 \
    || { cat /tmp/installer-static.log; exit 1; }
  grep -q "ALPINE_DISK_INSTALL_REACHED" /tmp/installer-static.log
  grep -q "192.168.50.2/24" /tmp/segment-ops
  grep -q "192.168.50.1" /tmp/segment-ops
  grep -q "9.9.9.9" /tmp/segment-ops
  echo "PASS static WAN provisioning and web admin password"
'