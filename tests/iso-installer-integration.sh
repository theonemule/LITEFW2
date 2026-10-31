#!/bin/sh
# Full LiteFW installer control flow, with disk/network tools mocked.
# A reported successful install MUST select, erase, and partition a disk.
set -eu
cd "$(dirname "$0")/.."
docker run --rm \
  -v "$PWD/iso/setup-alpine-litefwm:/usr/local/sbin/setup-alpine:ro" \
  -v "$PWD/bin/litefw-network:/usr/sbin/litefw-network:ro" \
  -v "$PWD/bin/litefw-admin:/usr/sbin/litefw-admin:ro" \
  alpine:3.24 sh -euc '
  apk add --quiet --no-cache alpine-conf apache2-utils lighttpd jq iproute2 util-linux >/dev/null
  mkdir -p /media/cdrom/apks /tmp/mocknet /etc/litefwm
  echo /media/cdrom/apks >>/etc/apk/repositories
  mknod /dev/litefw_test_disk b 7 200
  mknod /dev/litefw_other_disk b 7 201
  for tool in setup-interfaces setup-user setup-sshd passwd; do
    cat >"/usr/sbin/$tool" <<MOCK
#!/bin/sh
echo "FORBIDDEN_STOCK_WIZARD_$tool" >&2
exit 99
MOCK
    chmod 0755 "/usr/sbin/$tool"
  done
  for tool in setup-keymap setup-timezone setup-apkrepos; do
    cat >"/usr/sbin/$tool" <<MOCK
#!/bin/sh
echo "$tool \$*" >>/tmp/alpine-tools-called
MOCK
    chmod 0755 "/usr/sbin/$tool"
  done
  cat >/usr/sbin/setup-disk <<MOCK
#!/bin/sh
echo "setup-disk \$*" >>/tmp/alpine-tools-called
echo "\$*" > /tmp/disk-args
[ "\$1" = -m ] && [ "\$2" = sys ] && [ "\$3" = -s ] && [ "\$4" = 0 ] || exit 1
touch /tmp/setup-disk-ran
MOCK
  chmod 0755 /usr/sbin/setup-disk
  cat >/usr/sbin/lsblk <<MOCK
#!/bin/sh
if [ "\$1" = -dnpo ]; then
  [ "\${LITEFW_MOCK_NO_DISKS:-0}" != 1 ] || exit 0
  echo "/dev/litefw_test_disk 3G disk"
  [ "\${LITEFW_MOCK_TWO_DISKS:-0}" != 1 ] || echo "/dev/litefw_other_disk 5G disk"
elif [ "\$1" = -dno ]; then
  echo "litefw_test_disk 3G disk"
elif [ "\$1" = -nr ]; then
  echo disk
  if [ -e /tmp/setup-disk-ran ] && [ "\${LITEFW_MOCK_NO_PARTITIONS:-0}" != 1 ]; then echo part; fi
else
  echo "unexpected lsblk args: \$*" >&2; exit 1
fi
MOCK
  chmod 0755 /usr/sbin/lsblk
  cat >/usr/sbin/lfwctl <<MOCK
#!/bin/sh
if [ "\$1" = get ]; then echo "{\"interfaces\":[]}"; exit 0; fi
[ "\$1" = op ] || exit 1
printf "%s %s\n" "\$2" "\$3" >>/tmp/segment-ops
echo "{\"ok\":true}"
MOCK
  chmod 0755 /usr/sbin/lfwctl
  cat >/usr/sbin/ip <<MOCK
#!/bin/sh
case "\$1" in -4|link) exit 1;; esac
exit 0
MOCK
  chmod 0755 /usr/sbin/ip
  export LITEFW_SYS_NET=/tmp/mocknet LITEFW_DHCP_WAIT=1
  mkdir -p /tmp/mocknet/eth0
  : >/tmp/mocknet/eth0/device
  echo 1 >/tmp/mocknet/eth0/type

  # No physical disk is a HARD error; not a "success" with no OS installed.
  if LITEFW_MOCK_NO_DISKS=1 timeout 15 /usr/local/sbin/setup-alpine > /tmp/no-disk.log 2>&1; then
    echo "FAIL: no-disk install returned success" >&2; exit 1
  fi
  echo "=== no-disk test log ==="; cat /tmp/no-disk.log
  grep -q "No installation disk detected" /tmp/no-disk.log
  test ! -e /tmp/setup-disk-ran

  # One NIC; WAN DHCP timeout, no LAN. Real disk target and explicit ERASE.
  printf "\n\n\n\nnone\n\nOperator\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\nERASE\n" \
    | timeout 40 /usr/local/sbin/setup-alpine >/tmp/install.log 2>&1 \
    || { cat /tmp/install.log; exit 1; }
  grep -q "DHCP did not return" /tmp/install.log
  grep -q "SUCCESS: LiteFW installed to /dev/litefw_test_disk" /tmp/install.log
  grep -q "setup-disk -m sys -s 0 /dev/litefw_test_disk" /tmp/alpine-tools-called
  ! grep -q FORBIDDEN_STOCK_WIZARD /tmp/install.log
  ! grep -q SmokeTestOnlyPassword123 /tmp/install.log
  grep -q "wan.*dhcp" /tmp/segment-ops
  grep -q "wan.*none" /tmp/segment-ops
  htpasswd -vb /etc/litefwm/htpasswd Operator SmokeTestOnlyPassword123! >/dev/null
  echo "PASS: disk selected, format/install invoked, administrator is LiteFW web account"

  # Declining the erase confirmation MUST prevent the installation call.
  rm -f /tmp/setup-disk-ran /tmp/disk-args /etc/litefwm/htpasswd
  printf "\n\n\n\nnone\n\nAdminTwo\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\nno\n" \
    | timeout 40 /usr/local/sbin/setup-alpine >/tmp/decline.log 2>&1 \
    && { echo "FAIL: erase declined but install claimed success" >&2; exit 1; } || :
  test ! -e /tmp/setup-disk-ran
  ! grep -q "SUCCESS" /tmp/decline.log

  # An installer returning 0 without actually partitioning is ALSO an error.
  rm -f /tmp/setup-disk-ran
  printf "\n\n\n\nnone\n\nAdminTwo\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\nERASE\n" \
    | LITEFW_MOCK_NO_PARTITIONS=1 timeout 40 /usr/local/sbin/setup-alpine >/tmp/no-part.log 2>&1 \
    && { echo "FAIL: no-partition install claimed success" >&2; exit 1; } || :
  grep -q "without creating partitions" /tmp/no-part.log
  ! grep -q "SUCCESS" /tmp/no-part.log

  # Multi-NIC network and TWO eligible disks: explicit selection of disk 2.
  for i in eth1 eth2; do
    mkdir -p "/tmp/mocknet/$i"; : >"/tmp/mocknet/$i/device"; echo 1 >"/tmp/mocknet/$i/type"
  done
  rm -f /tmp/segment-ops /tmp/alpine-tools-called /tmp/setup-disk-ran /etc/litefwm/htpasswd
  printf "2\n\n\nstatic\n192.168.50.2/24\n192.168.50.1\n9.9.9.9\nyes\n20\n192.168.20.1/24\n\nNewAdmin\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\nERASE\n" \
    | LITEFW_MOCK_TWO_DISKS=1 timeout 40 /usr/local/sbin/setup-alpine >/tmp/static.log 2>&1 \
    || { cat /tmp/static.log; exit 1; }
  grep -q "setup-disk -m sys -s 0 /dev/litefw_other_disk" /tmp/alpine-tools-called
  grep -q "SUCCESS: LiteFW installed to /dev/litefw_other_disk" /tmp/static.log
  grep -q "vlan.create" /tmp/segment-ops
  grep -q "parent.*eth1" /tmp/segment-ops
  grep -q "vid.*20" /tmp/segment-ops
  grep -q "interface.*eth1.20.*role.*lan" /tmp/segment-ops
  grep -q "192.168.50.2/24" /tmp/segment-ops
  grep -q "192.168.50.1" /tmp/segment-ops
  grep -q "9.9.9.9" /tmp/segment-ops
  ! grep -q eth2 /tmp/segment-ops
  htpasswd -vb /etc/litefwm/htpasswd NewAdmin SmokeTestOnlyPassword123! >/dev/null
  echo "PASS: two-disk target selection, static WAN, optional VLAN LAN, unassigned NIC"

  # Still permit optional Alpine mirrors WITHOUT invoking Alpine network setup.
  rm -f /tmp/alpine-tools-called /tmp/setup-disk-ran /etc/litefwm/htpasswd
  rm -rf /tmp/mocknet/eth0 /tmp/mocknet/eth1 /tmp/mocknet/eth2
  printf "\nyes\nWebAdmin\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\nERASE\n" \
    | timeout 30 /usr/local/sbin/setup-alpine >/tmp/mirrors.log 2>&1 \
    || { cat /tmp/mirrors.log; exit 1; }
  grep -q "setup-apkrepos" /tmp/alpine-tools-called
  grep -q "setup-keymap" /tmp/alpine-tools-called
  grep -q "setup-timezone" /tmp/alpine-tools-called
  htpasswd -vb /etc/litefwm/htpasswd WebAdmin SmokeTestOnlyPassword123! >/dev/null
  echo "PASS: regional, package and web-admin setup while still installing to disk"
'