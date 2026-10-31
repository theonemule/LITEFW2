#!/bin/sh
# Exercise the real one-command wrapper and both LiteFW wizards on Alpine.
set -eu
cd "$(dirname "$0")/.."
docker run --rm \
  -v "$PWD/iso/setup-alpine-litefwm:/usr/local/sbin/setup-alpine:ro" \
  -v "$PWD/bin/litefw-network:/usr/sbin/litefw-network:ro" \
  -v "$PWD/bin/litefw-admin:/usr/sbin/litefw-admin:ro" \
  alpine:3.24 sh -euc '
  apk add --quiet --no-cache alpine-conf apache2-utils lighttpd jq iproute2 >/dev/null
  grep -qx "# set Interface" /usr/sbin/setup-alpine
  grep -q "^print_heading2 \" Disk & Install\"$" /usr/sbin/setup-alpine
  cat >/usr/sbin/setup-alpine <<\MOCK
#!/bin/sh
[ "$1" = "-e" ] || { echo "missing root-password suppression" >&2; exit 1; }
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
echo STOCK_NETWORK_WAS_CALLED >&2
exit 1
MOCK
  chmod +x /usr/sbin/setup-interfaces
  cat >/usr/sbin/lfwctl <<\MOCK
#!/bin/sh
if [ "$1" = get ]; then
  echo "{\"interfaces\":[]}"
  exit 0
fi
[ "$1" = op ] || exit 1
printf "%s %s\n" "$2" "$3" >>/tmp/segment-ops
echo "{\"ok\":true}"
MOCK
  chmod +x /usr/sbin/lfwctl
  cat >/usr/sbin/ip <<\MOCK
#!/bin/sh
# Simulate an unnumbered WAN and an absent tagged VLAN interface.
case "$1" in -4|link) exit 1;; esac
exit 0
MOCK
  chmod +x /usr/sbin/ip
  export LITEFW_SYS_NET=/tmp/mocknet LITEFW_DHCP_WAIT=1
  mkdir -p /tmp/mocknet/eth0
  : >/tmp/mocknet/eth0/device
  echo 1 >/tmp/mocknet/eth0/type
  # One-NIC offline case: DHCP fails, administrator chooses no WAN address.
  printf "\n\n\nnone\nOperator\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 30 /usr/local/sbin/setup-alpine >/tmp/installer.log 2>&1 \
    || { cat /tmp/installer.log; exit 1; }
  grep -q "DHCP did not return" /tmp/installer.log
  grep -q "ALPINE_DISK_INSTALL_REACHED" /tmp/installer.log
  ! grep -q "STOCK_NETWORK_WAS_CALLED" /tmp/installer.log
  grep -q "wan.*dhcp" /tmp/segment-ops
  grep -q "wan.*none" /tmp/segment-ops
  htpasswd -vb /etc/litefwm/htpasswd Operator SmokeTestOnlyPassword123! >/dev/null
  ! grep -q SmokeTestOnlyPassword123 /tmp/installer.log
  echo "PASS offline DHCP fallback and named web administrator"
  # Three NICs: exactly WAN eth0, tagged LAN eth1.20, eth2 unassigned.
  for i in eth1 eth2; do
    mkdir -p "/tmp/mocknet/$i"
    : >"/tmp/mocknet/$i/device"
    echo 1 >"/tmp/mocknet/$i/type"
  done
  rm -f /tmp/segment-ops /etc/litefwm/htpasswd
  printf "\n\nstatic\n192.168.50.2/24\n192.168.50.1\n9.9.9.9\nyes\n20\n192.168.20.1/24\nNewAdmin\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 20 /usr/local/sbin/setup-alpine >/tmp/installer-static.log 2>&1 \
    || { cat /tmp/installer-static.log; exit 1; }
  grep -q "ALPINE_DISK_INSTALL_REACHED" /tmp/installer-static.log
  grep -q "vlan.create" /tmp/segment-ops
  grep -q "parent.*eth1" /tmp/segment-ops
  grep -q "vid.*20" /tmp/segment-ops
  grep -q "interface.*eth1.20.*role.*lan" /tmp/segment-ops
  grep -q "192.168.50.2/24" /tmp/segment-ops
  grep -q "192.168.50.1" /tmp/segment-ops
  grep -q "9.9.9.9" /tmp/segment-ops
  ! grep -q "eth2" /tmp/segment-ops
  htpasswd -vb /etc/litefwm/htpasswd NewAdmin SmokeTestOnlyPassword123! >/dev/null
  echo "PASS WAN static, tagged LAN, unused NIC, and admin rename"
'
