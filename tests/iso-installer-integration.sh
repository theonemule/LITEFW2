#!/bin/sh
# Exercise the REAL LiteFW installer flow with Alpine regional/disk utilities
# mocked. Any invocation of Alpine account/network setup fails the test.
set -eu
cd "$(dirname "$0")/.."
docker run --rm \
  -v "$PWD/iso/setup-alpine-litefwm:/usr/local/sbin/setup-alpine:ro" \
  -v "$PWD/bin/litefw-network:/usr/sbin/litefw-network:ro" \
  -v "$PWD/bin/litefw-admin:/usr/sbin/litefw-admin:ro" \
  alpine:3.24 sh -euc '
  apk add --quiet --no-cache alpine-conf apache2-utils lighttpd jq iproute2 >/dev/null
  mkdir -p /media/cdrom/apks /tmp/mocknet /etc/litefwm
  echo /media/cdrom/apks >>/etc/apk/repositories
  for tool in setup-interfaces setup-user setup-sshd setup-alpine passwd; do
    cat >"/usr/sbin/$tool" <<MOCK
#!/bin/sh
echo "FORBIDDEN_STOCK_WIZARD_$tool" >&2
exit 99
MOCK
    chmod 0755 "/usr/sbin/$tool"
  done
  for tool in setup-keymap setup-timezone setup-apkrepos setup-disk; do
    cat >"/usr/sbin/$tool" <<MOCK
#!/bin/sh
echo "$tool \$*" >>/tmp/alpine-tools-called
echo "MOCK_$tool"
MOCK
    chmod 0755 "/usr/sbin/$tool"
  done
  cat >/usr/sbin/lfwctl <<MOCK
#!/bin/sh
if [ "\$1" = get ]; then
  echo "{\"interfaces\":[]}"
  exit 0
fi
[ "\$1" = op ] || exit 1
printf "%s %s\n" "\$2" "\$3" >>/tmp/segment-ops
echo "{\"ok\":true}"
MOCK
  chmod +x /usr/sbin/lfwctl
  cat >/usr/sbin/ip <<MOCK
#!/bin/sh
case "\$1" in -4|link) exit 1;; esac
exit 0
MOCK
  chmod +x /usr/sbin/ip
  export LITEFW_SYS_NET=/tmp/mocknet LITEFW_DHCP_WAIT=1
  mkdir -p /tmp/mocknet/eth0
  : >/tmp/mocknet/eth0/device
  echo 1 >/tmp/mocknet/eth0/type

  # Single NIC, bounded DHCP and offline fallback.
  printf "\n\n\nnone\n\nOperator\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 40 /usr/local/sbin/setup-alpine >/tmp/installer.log 2>&1 \
    || { cat /tmp/installer.log; exit 1; }
  grep -q "DHCP did not return" /tmp/installer.log
  grep -q "LiteFW installation complete" /tmp/installer.log
  grep -q "setup-disk -m sys -s 0" /tmp/alpine-tools-called
  grep -q "setup-keymap" /tmp/alpine-tools-called
  grep -q "setup-timezone" /tmp/alpine-tools-called
  ! grep -q "setup-apkrepos" /tmp/alpine-tools-called
  ! grep -q FORBIDDEN_STOCK_WIZARD /tmp/installer.log
  ! grep -q SmokeTestOnlyPassword123 /tmp/installer.log
  grep -q "wan.*dhcp" /tmp/segment-ops
  grep -q "wan.*none" /tmp/segment-ops
  htpasswd -vb /etc/litefwm/htpasswd Operator SmokeTestOnlyPassword123! >/dev/null
  echo "PASS native LiteFW wizard: offline WAN, UI administrator, no Alpine account/network prompts"

  # Three NICs: exactly WAN eth0 and tagged LAN eth1.20; eth2 unassigned.
  for i in eth1 eth2; do
    mkdir -p "/tmp/mocknet/$i"
    : >"/tmp/mocknet/$i/device"
    echo 1 >"/tmp/mocknet/$i/type"
  done
  rm -f /tmp/segment-ops /tmp/alpine-tools-called /etc/litefwm/htpasswd
  printf "\n\nstatic\n192.168.50.2/24\n192.168.50.1\n9.9.9.9\nyes\n20\n192.168.20.1/24\n\nNewAdmin\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 35 /usr/local/sbin/setup-alpine >/tmp/installer-static.log 2>&1 \
    || { cat /tmp/installer-static.log; exit 1; }
  grep -q "LiteFW installation complete" /tmp/installer-static.log
  grep -q "vlan.create" /tmp/segment-ops
  grep -q "parent.*eth1" /tmp/segment-ops
  grep -q "vid.*20" /tmp/segment-ops
  grep -q "interface.*eth1.20.*role.*lan" /tmp/segment-ops
  grep -q "192.168.50.2/24" /tmp/segment-ops
  grep -q "192.168.50.1" /tmp/segment-ops
  grep -q "9.9.9.9" /tmp/segment-ops
  ! grep -q eth2 /tmp/segment-ops
  ! grep -q FORBIDDEN_STOCK_WIZARD /tmp/installer-static.log
  htpasswd -vb /etc/litefwm/htpasswd NewAdmin SmokeTestOnlyPassword123! >/dev/null
  echo "PASS native LiteFW wizard: static WAN, optional VLAN LAN, unassigned NIC, web admin rename"

  # Optional APK mirror configuration is available and not forced offline.
  rm -f /tmp/alpine-tools-called /etc/litefwm/htpasswd
  rm -rf /tmp/mocknet/eth0 /tmp/mocknet/eth1 /tmp/mocknet/eth2
  printf "yes\nWebAdmin\nSmokeTestOnlyPassword123!\nSmokeTestOnlyPassword123!\n" \
    | timeout 25 /usr/local/sbin/setup-alpine >/tmp/installer-mirrors.log 2>&1 \
    || { cat /tmp/installer-mirrors.log; exit 1; }
  grep -q "setup-apkrepos" /tmp/alpine-tools-called
  htpasswd -vb /etc/litefwm/htpasswd WebAdmin SmokeTestOnlyPassword123! >/dev/null
  echo "PASS optional Alpine repository setup without Alpine network or user wizard"
'