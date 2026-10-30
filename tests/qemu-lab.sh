#!/bin/bash
# LiteFWM two-interface QEMU lab.
#
#   outside 172.30.50.100
#            |
#     lfw2wan bridge -- host 172.30.50.1
#            |
#       eth0 172.30.50.2
#        [ LiteFWM ]
#       eth1 172.30.60.1
#            |
#     lfw2lan bridge -- host 172.30.60.254 (lab management only)
#          /     \
#       app1     app2
#      .60.11   .60.12
#
# Each Alpine VM has 512 MiB RAM and a 4 GiB sparse qcow2 disk. When /dev/kvm
# is unavailable QEMU runs with TCG, which is slower but exercises the same
# Ethernet bridge, routing, firewall and NAT behavior.
#
# Commands: boot | install | up | test | status | down
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
LAB=${LFW_QEMU_LAB_DIR:-/tmp/litefwm2-qemu-lab}
BASE=${LFW_QEMU_BASE:-/tmp/litefwm-qemu/base.qcow2}
PASS=${LFW_QEMU_PASSWORD:-pwd1234}

BR_WAN=lfw2wan
BR_LAN=lfw2lan
TAP_FW_WAN=lfw2fw0
TAP_FW_LAN=lfw2fw1
TAP_APP1=lfw2app1
TAP_APP2=lfw2app2
OUT_NS=lfw2out
OUT_HOST=lfw2outh
OUT_NS_IF=lfw2outn

WAN_NET=172.30.50.0/24
HOST_WAN=172.30.50.1
FW_WAN=172.30.50.2
OUTSIDE=172.30.50.100
HOST_LAN=172.30.60.254
FW_LAN=172.30.60.1
APP1=172.30.60.11
APP2=172.30.60.12
COMMENT=litefwm2-qemu-lab

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
msg() { printf '\n==> %s\n' "$*"; }

ssh_vm() {
  local ip=$1; shift
  sshpass -p "$PASS" ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=4 root@"$ip" "$@"
}
wait_ssh() {
  local name=$1 ip=$2
  for _ in $(seq 1 90); do
    if ssh_vm "$ip" 'echo ready' >/dev/null 2>&1; then
      echo "    $name ready at $ip"
      return 0
    fi
    sleep 1
  done
  echo "$name did not become reachable at $ip" >&2
  tail -80 "$LAB/$name.serial.log" 2>/dev/null || true
  return 1
}

ipt_add() {
  local table=$1; shift
  sudo iptables -t "$table" -C "$@" >/dev/null 2>&1 || sudo iptables -t "$table" -A "$@"
}
ipt_del() {
  local table=$1; shift
  while sudo iptables -t "$table" -C "$@" >/dev/null 2>&1; do sudo iptables -t "$table" -D "$@"; done
}

nbd_mount() {
  local disk=$1 mount=$2
  sudo qemu-nbd --disconnect /dev/nbd12 >/dev/null 2>&1 || true
  sudo qemu-nbd --connect=/dev/nbd12 "$disk"
  sudo partprobe /dev/nbd12
  sleep .2
  mkdir -p "$mount"
  sudo mount /dev/nbd12p3 "$mount"
}
nbd_umount() {
  local mount=$1
  sudo umount "$mount"
  sudo qemu-nbd --disconnect /dev/nbd12 >/dev/null
}

make_disk() {
  local name=$1 rc=0
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$LAB/$name.qcow2" 4G
  sudo qemu-nbd --disconnect /dev/nbd12 >/dev/null 2>&1 || true
  sudo qemu-nbd --connect=/dev/nbd12 "$LAB/$name.qcow2"
  sudo partprobe /dev/nbd12
  sleep .2
  sudo growpart /dev/nbd12 3 >/dev/null
  sudo e2fsck -fy /dev/nbd12p3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -le 1 ] || { sudo qemu-nbd --disconnect /dev/nbd12; return "$rc"; }
  sudo resize2fs /dev/nbd12p3 >/dev/null
  sudo qemu-nbd --disconnect /dev/nbd12 >/dev/null
}

prepare_guest() {
  local name=$1 addr0=$2 gateway=$3 addr1=${4:-}
  local m="$LAB/mnt-$name" hash
  hash=$(openssl passwd -6 "$PASS")
  nbd_mount "$LAB/$name.qcow2" "$m"

  printf '%s\n' "$name" | sudo tee "$m/etc/hostname" >/dev/null
  sudo sed -i "s#^root:[^:]*:#root:$hash:#" "$m/etc/shadow"
  sudo mkdir -p "$m/etc/ssh/sshd_config.d"
  sudo tee "$m/etc/ssh/sshd_config.d/99-lfw2-lab.conf" >/dev/null <<'SSHCONF'
PermitRootLogin yes
PasswordAuthentication yes
SSHCONF
  # Make boot deterministic under TCG: this lab writes native network files
  # directly, so cloud-init is not needed after the disk is cloned.
  sudo find "$m/etc/runlevels" -type l \( -name 'cloud-*' -o -name 'cloud-init' -o -name 'cloud-init-hotplugd' \) -delete 2>/dev/null || true
  sudo ln -sf /etc/init.d/networking "$m/etc/runlevels/default/networking"
  sudo ln -sf /etc/init.d/sshd "$m/etc/runlevels/default/sshd"

  {
    echo 'auto lo'
    echo 'iface lo inet loopback'
    echo
    echo 'auto eth0'
    echo 'iface eth0 inet static'
    echo "    address $addr0/24"
    [ -z "$gateway" ] || echo "    gateway $gateway"
    if [ -n "$addr1" ]; then
      echo
      echo 'auto eth1'
      echo 'iface eth1 inet static'
      echo "    address $addr1/24"
    fi
  } | sudo tee "$m/etc/network/interfaces" >/dev/null
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee "$m/etc/resolv.conf" >/dev/null

  # Generate unique host keys if the base image does not contain them.
  if [ ! -s "$m/etc/ssh/ssh_host_ed25519_key" ]; then
    sudo ssh-keygen -q -t ed25519 -N '' -f "$m/etc/ssh/ssh_host_ed25519_key"
  fi
  if [ ! -s "$m/etc/ssh/ssh_host_rsa_key" ]; then
    sudo ssh-keygen -q -t rsa -b 3072 -N '' -f "$m/etc/ssh/ssh_host_rsa_key"
  fi

  if [ "$name" = app1 ] || [ "$name" = app2 ]; then
    sudo mkdir -p "$m/www" "$m/etc/local.d"
    printf 'hello-from-%s\n' "$name" | sudo tee "$m/www/index.html" >/dev/null
    sudo tee "$m/etc/local.d/lfw2-httpd.start" >/dev/null <<'HTTPD'
#!/bin/sh
httpd -p 80 -h /www
HTTPD
    sudo chmod 0755 "$m/etc/local.d/lfw2-httpd.start"
    sudo ln -sf /etc/init.d/local "$m/etc/runlevels/default/local"
  fi

  nbd_umount "$m"
  rmdir "$m" 2>/dev/null || true
}

make_tap() {
  local tap=$1 bridge=$2
  sudo ip tuntap add dev "$tap" mode tap user "$(id -u)"
  sudo ip link set "$tap" master "$bridge"
  sudo ip link set "$tap" up
}

start_vm() {
  local name=$1 tap0=$2 mac0=$3 tap1=${4:-} mac1=${5:-}
  local accel=tcg
  [ -e /dev/kvm ] && accel=kvm
  local args=(
    qemu-system-x86_64 -name "lfw2-$name" -machine "accel=$accel" -cpu qemu64 -smp 1 -m 512M
    -drive "file=$LAB/$name.qcow2,if=virtio,format=qcow2"
    -netdev "tap,id=n0,ifname=$tap0,script=no,downscript=no"
    -device "virtio-net-pci,netdev=n0,mac=$mac0"
    -display none -serial "file:$LAB/$name.serial.log" -monitor none
    -pidfile "$LAB/$name.pid" -daemonize
  )
  if [ -n "$tap1" ]; then
    args+=( -netdev "tap,id=n1,ifname=$tap1,script=no,downscript=no" -device "virtio-net-pci,netdev=n1,mac=$mac1" )
  fi
  "${args[@]}"
}

api() {
  local path=$1; shift || true
  local auth
  [ -r "$LAB/env" ] || { echo 'LiteFWM is not installed in the lab yet' >&2; return 1; }
  auth=$(sed -n 's/^API_PASSWORD=//p' "$LAB/env")
  curl -fsS -u "admin:$auth" "$@" "http://$FW_WAN/api/$path"
}
api_post() {
  local path=$1 body=$2
  api "$path" -H 'X-LiteFWM: 1' -H 'Content-Type: application/json' -d "$body"
}

boot_lab() {
  for c in qemu-system-x86_64 qemu-img qemu-nbd growpart resize2fs sshpass openssl ip iptables; do need "$c"; done
  [ -r "$BASE" ] || { echo "base image not found: $BASE" >&2; exit 1; }
  down >/dev/null 2>&1 || true
  mkdir -p "$LAB"

  msg "host bridges and WAN-only test node"
  sudo ip link add "$BR_WAN" type bridge
  sudo ip addr add "$HOST_WAN/24" dev "$BR_WAN"
  sudo ip link set "$BR_WAN" up
  sudo ip link add "$BR_LAN" type bridge
  sudo ip addr add "$HOST_LAN/24" dev "$BR_LAN"
  sudo ip link set "$BR_LAN" up

  sudo ip netns add "$OUT_NS"
  sudo ip link add "$OUT_HOST" type veth peer name "$OUT_NS_IF"
  sudo ip link set "$OUT_HOST" master "$BR_WAN"
  sudo ip link set "$OUT_HOST" up
  sudo ip link set "$OUT_NS_IF" netns "$OUT_NS"
  sudo ip netns exec "$OUT_NS" ip link set lo up
  sudo ip netns exec "$OUT_NS" ip link set "$OUT_NS_IF" name eth0
  sudo ip netns exec "$OUT_NS" ip addr add "$OUTSIDE/24" dev eth0
  sudo ip netns exec "$OUT_NS" ip link set eth0 up
  mkdir -p "$LAB/outside-www"
  printf 'outside\n' >"$LAB/outside-www/index.html"
  sudo ip netns exec "$OUT_NS" busybox httpd -p 8088 -h "$LAB/outside-www"

  msg "temporary host NAT for Alpine package installation"
  EXT_IF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [ -n "$EXT_IF" ] || { echo 'could not determine host uplink' >&2; exit 1; }
  printf 'EXT_IF=%s\n' "$EXT_IF" >"$LAB/host.env"
  cat /proc/sys/net/ipv4/ip_forward >"$LAB/ip_forward.orig"
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ipt_add nat POSTROUTING -s "$WAN_NET" -o "$EXT_IF" -m comment --comment "$COMMENT" -j MASQUERADE
  ipt_add filter FORWARD -i "$BR_WAN" -o "$EXT_IF" -m comment --comment "$COMMENT" -j ACCEPT
  ipt_add filter FORWARD -i "$EXT_IF" -o "$BR_WAN" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$COMMENT" -j ACCEPT

  msg "4 GiB Alpine disks"
  for vm in fw app1 app2; do make_disk "$vm"; done
  prepare_guest fw "$FW_WAN" "$HOST_WAN" "$FW_LAN"
  prepare_guest app1 "$APP1" "$FW_LAN"
  prepare_guest app2 "$APP2" "$FW_LAN"

  msg "TAP interfaces and QEMU VMs"
  make_tap "$TAP_FW_WAN" "$BR_WAN"
  make_tap "$TAP_FW_LAN" "$BR_LAN"
  make_tap "$TAP_APP1" "$BR_LAN"
  make_tap "$TAP_APP2" "$BR_LAN"
  start_vm fw   "$TAP_FW_WAN" 52:54:00:50:00:02 "$TAP_FW_LAN" 52:54:00:60:00:01
  start_vm app1 "$TAP_APP1"   52:54:00:60:00:11
  start_vm app2 "$TAP_APP2"   52:54:00:60:00:12

  msg "waiting for Alpine guests"
  wait_ssh fw "$FW_WAN"
  wait_ssh app1 "$APP1"
  wait_ssh app2 "$APP2"
  status
}

install_litefwm() {
  wait_ssh fw "$FW_WAN"
  wait_ssh app1 "$APP1"
  wait_ssh app2 "$APP2"

  msg "install current litefwm2 tree on the two-NIC firewall"
  tar -C "$ROOT" --exclude=.git -czf - . | \
    sshpass -p "$PASS" ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$FW_WAN" \
      'mkdir -p /root/litefwm2 && tar xzf - -C /root/litefwm2'
  INSTALL_OUT=$(ssh_vm "$FW_WAN" 'cd /root/litefwm2 && ./install.sh --admin-user admin')
  printf '%s\n' "$INSTALL_OUT"
  API_PASSWORD=$(printf '%s\n' "$INSTALL_OUT" | sed -n 's/^    admin login: admin \/ //p' | tail -1)
  if [ -z "$API_PASSWORD" ] && [ -r "$LAB/env" ]; then
    API_PASSWORD=$(sed -n 's/^API_PASSWORD=//p' "$LAB/env")
  fi
  [ -n "$API_PASSWORD" ] || { echo 'could not determine LiteFWM admin password' >&2; exit 1; }
  umask 077
  cat >"$LAB/env" <<ENV
API_PASSWORD=$API_PASSWORD
FW_WAN=$FW_WAN
FW_LAN=$FW_LAN
APP1=$APP1
APP2=$APP2
OUTSIDE=$OUTSIDE
ENV

  msg "configure LAN, forward policy and test publication through resource APIs"
  api_post segments/set '{"interface":"eth1","label":"LAB-LAN","role":"lan","mode":"static","addresses":["172.30.60.1/24"]}' | jq -e '.ok' >/dev/null
  if ! api firewall | jq -e '.firewall.rules[] | select(.description=="lab LAN to WAN")' >/dev/null; then
    api_post firewall/rules/add '{"chain":"forward","action":"accept","in":"eth1","out":"eth0","description":"lab LAN to WAN"}' | jq -e '.ok' >/dev/null
  fi
  if ! api port-forwards | jq -e '.firewall.forwards[] | select(.description=="lab app1 web")' >/dev/null; then
    api_post port-forwards/add '{"proto":"tcp","port":"8080","to":"172.30.60.11","toPort":"80","description":"lab app1 web"}' | jq -e '.ok' >/dev/null
  fi

  msg "install tiny backend HTTP service through the firewall"
  # busybox-extras provides Alpine's httpd applet. Installing it from the two
  # private guests proves their default route + LiteFWM forwarding/NAT path.
  ssh_vm "$APP1" 'apk add -q --no-cache busybox-extras >/dev/null && rc-service local restart >/dev/null' & p1=$!
  ssh_vm "$APP2" 'apk add -q --no-cache busybox-extras >/dev/null && rc-service local restart >/dev/null' & p2=$!
  wait "$p1"; wait "$p2"

  echo
  echo "UI: http://$FW_WAN/"
  echo "UI user: admin"
  echo "UI password: $API_PASSWORD"
  echo "VM root password: $PASS"
}

test_lab() {
  [ -r "$LAB/env" ] || { echo 'LiteFWM is not installed in the lab yet' >&2; exit 1; }
  local pass=0 fail=0
  check() {
    local text=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$text"; pass=$((pass+1));
    else printf '  FAIL %s\n' "$text"; fail=$((fail+1)); fi
  }

  msg "VM topology"
  if sudo ip netns exec "$OUT_NS" ping -c1 -W2 "$FW_WAN" >/dev/null 2>&1; then
    echo '  FAIL WAN ICMP should be blocked by default INPUT policy'; fail=$((fail+1))
  else
    echo '  ok   WAN ICMP is blocked by default INPUT policy'; pass=$((pass+1))
  fi
  check 'firewall LAN responds' ping -c1 -W2 "$FW_LAN"
  check 'app1 responds on LAN' ping -c1 -W2 "$APP1"
  check 'app2 responds on LAN' ping -c1 -W2 "$APP2"
  check 'app1 default route is the firewall' ssh_vm "$APP1" "ip route | grep -q 'default via $FW_LAN'"
  check 'app2 default route is the firewall' ssh_vm "$APP2" "ip route | grep -q 'default via $FW_LAN'"
  check 'app1 and app2 share the private LAN' ssh_vm "$APP1" "ping -c1 -W2 $APP2"

  msg "routing and NAT through LiteFWM"
  check 'app1 reaches WAN-only node through firewall/NAT' ssh_vm "$APP1" "wget -q -T 5 -O - http://$OUTSIDE:8088/ | grep -q outside"
  check 'app2 reaches WAN-only node through firewall/NAT' ssh_vm "$APP2" "wget -q -T 5 -O - http://$OUTSIDE:8088/ | grep -q outside"
  check 'outside node has no direct route to private LAN' sudo ip netns exec "$OUT_NS" sh -c "! ip route get $APP1 >/dev/null 2>&1"
  check 'WAN port 8080 forwards to app1 port 80' sudo ip netns exec "$OUT_NS" busybox wget -q -T 5 -O - "http://$FW_WAN:8080/"

  msg "resource API"
  for resource in identity overview interfaces segments firewall port-forwards dhcp dns modules system; do
    check "GET /api/$resource" api "$resource"
  done
  local physical wan_role lan_role bind_installed
  physical=$(api interfaces | jq '[.interfaces[] | select(.kind=="physical")] | length')
  wan_role=$(api segments | jq -r '.interfaces[]|select(.name=="eth0")|.role')
  lan_role=$(api segments | jq -r '.interfaces[]|select(.name=="eth1")|.role')
  bind_installed=$(api modules | jq -r '.modules[]|select(.id=="bind")|.installed')
  if [ "$physical" -eq 2 ]; then echo '  ok   firewall exposes exactly two physical interfaces'; pass=$((pass+1));
  else echo '  FAIL firewall exposes exactly two physical interfaces'; fail=$((fail+1)); fi
  if [ "$wan_role:$lan_role" = 'wan:lan' ]; then echo '  ok   segment API reports WAN eth0 and LAN eth1'; pass=$((pass+1));
  else echo '  FAIL segment API roles'; fail=$((fail+1)); fi
  if [ "$bind_installed" = false ]; then echo '  ok   optional BIND is not installed / not shown on DNS page'; pass=$((pass+1));
  else echo '  FAIL optional BIND install state'; fail=$((fail+1)); fi

  msg "appliance setup and logging"
  check 'lfw-setup recovery tool is installed' ssh_vm "$FW_WAN" "test -x /usr/sbin/lfw-setup"
  check 'lfw-setup reads live WAN and LAN roles' ssh_vm "$FW_WAN" "lfw-setup show | grep -q 'eth0.*wan' && lfw-setup show | grep -q 'eth1.*lan'"
  check 'lfw-setup WAN command preserves the live uplink' ssh_vm "$FW_WAN" "lfw-setup wan eth0 >/dev/null"
  check 'lfw-setup LAN command preserves the live internal segment' ssh_vm "$FW_WAN" "lfw-setup lan eth1 >/dev/null"
  logging_ok=$(api system | jq -r '.system.logging.serviceRunning == true and .system.logging.protocol == "udp"')
  if [ "$logging_ok" = true ]; then echo '  ok   system API reports native syslog service'; pass=$((pass+1));
  else echo '  FAIL system API reports native syslog service'; fail=$((fail+1)); fi
  check 'native syslog config is still the source of truth' ssh_vm "$FW_WAN" "grep -q '^SYSLOGD_OPTS=' /etc/conf.d/syslog"
  check 'routing still works after console role re-apply' ssh_vm "$APP1" "wget -q -T 5 -O - http://$OUTSIDE:8088/ | grep -q outside"

  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

status() {
  printf '%-10s %-24s %-8s %-8s\n' NAME ADDRESS RAM DISK
  printf '%-10s %-24s %-8s %-8s\n' firewall "$FW_WAN / $FW_LAN" 512MiB 4GiB
  printf '%-10s %-24s %-8s %-8s\n' app1 "$APP1" 512MiB 4GiB
  printf '%-10s %-24s %-8s %-8s\n' app2 "$APP2" 512MiB 4GiB
  echo
  ip -br addr show "$BR_WAN" "$BR_LAN" 2>/dev/null || true
  for vm in fw app1 app2; do
    if [ -r "$LAB/$vm.pid" ] && kill -0 "$(cat "$LAB/$vm.pid")" 2>/dev/null; then echo "$vm: running pid $(cat "$LAB/$vm.pid")"; else echo "$vm: stopped"; fi
  done
  if [ -r "$LAB/env" ]; then
    echo "UI: http://$FW_WAN/"
    echo "UI user: admin"
    echo "UI password: $(sed -n 's/^API_PASSWORD=//p' "$LAB/env")"
  fi
}

down() {
  if [ -d "$LAB" ]; then
    for vm in fw app1 app2; do
      if [ -r "$LAB/$vm.pid" ]; then
        pid=$(cat "$LAB/$vm.pid" 2>/dev/null || true)
        [ -z "$pid" ] || kill "$pid" >/dev/null 2>&1 || true
      fi
    done
    sleep .5
  fi
  if sudo ip netns list 2>/dev/null | grep -q "^$OUT_NS\b"; then
    for p in $(sudo ip netns pids "$OUT_NS" 2>/dev/null); do sudo kill "$p" >/dev/null 2>&1 || true; done
    sudo ip netns del "$OUT_NS" >/dev/null 2>&1 || true
  fi
  for tap in "$TAP_FW_WAN" "$TAP_FW_LAN" "$TAP_APP1" "$TAP_APP2" "$OUT_HOST"; do sudo ip link del "$tap" >/dev/null 2>&1 || true; done
  if [ -r "$LAB/host.env" ]; then
    # shellcheck disable=SC1090
    . "$LAB/host.env"
    ipt_del nat POSTROUTING -s "$WAN_NET" -o "$EXT_IF" -m comment --comment "$COMMENT" -j MASQUERADE || true
    ipt_del filter FORWARD -i "$BR_WAN" -o "$EXT_IF" -m comment --comment "$COMMENT" -j ACCEPT || true
    ipt_del filter FORWARD -i "$EXT_IF" -o "$BR_WAN" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$COMMENT" -j ACCEPT || true
  fi
  sudo ip link del "$BR_LAN" >/dev/null 2>&1 || true
  sudo ip link del "$BR_WAN" >/dev/null 2>&1 || true
  if [ -r "$LAB/ip_forward.orig" ] && [ "$(cat "$LAB/ip_forward.orig")" = 0 ]; then sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null; fi
  sudo qemu-nbd --disconnect /dev/nbd12 >/dev/null 2>&1 || true
  [ ! -d "$LAB" ] || rm -rf "$LAB"
}

case "${1:-}" in
  boot) boot_lab;;
  install) install_litefwm;;
  up) boot_lab; install_litefwm;;
  test) test_lab;;
  status) status;;
  down) down;;
  *) sed -n '2,26p' "$0"; exit 2;;
esac
