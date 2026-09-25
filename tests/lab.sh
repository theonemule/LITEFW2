#!/bin/bash
# LiteFWM end-to-end lab (runs on a Docker host; needs sudo docker).
#
#   isp    : upstream router - DHCP server for the WAN, HTTP "internet" endpoint
#   fw     : Alpine appliance with 3 NICs (wan, lan, trunk); LiteFWM installed
#   lan1   : client on the LAN
#   trunk1 : client on VLAN 20 of the trunk
#
#   tests/lab.sh up      build the lab and install LiteFWM (fw starts as fresh Alpine: WAN DHCP)
#   tests/lab.sh test    run the functional test suite against the lab (HTTP API)
#   tests/lab.sh ui      drive the web UI in headless Chrome (needs playwright-core; PLAYWRIGHT_CORE=path)
#   tests/lab.sh down    remove everything
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
D="sudo docker"
IMG=${LFW_LAB_IMAGE:-alpine:3.24}
P=lfwlab

x() { local c=$1; shift; $D exec "$P-$c" sh -c "$*"; }

up() {
  $D network create --subnet 10.250.0.0/24 --ip-range 10.250.0.0/27 --gateway 10.250.0.1 $P-wan >/dev/null
  $D network create --subnet 10.251.0.0/24 --gateway 10.251.0.1 $P-lan >/dev/null
  $D network create --subnet 10.252.0.0/24 --gateway 10.252.0.1 $P-trunk >/dev/null

  # ISP: router to the real internet (via the docker gateway), DHCP for the WAN
  $D run -d --name $P-isp --hostname isp --cap-add NET_ADMIN --cap-add NET_RAW \
     --network $P-wan --ip 10.250.0.2 $IMG sleep infinity >/dev/null
  x isp 'apk add -q --no-cache dnsmasq busybox-extras >/dev/null
    mkdir -p /www/cgi-bin
    printf "#!/bin/sh\necho Content-Type: text/plain\necho\necho \$REMOTE_ADDR\n" >/www/cgi-bin/ip
    chmod +x /www/cgi-bin/ip; echo internet >/www/index.html
    busybox-extras httpd -p 80 -h /www
    dnsmasq --dhcp-range=10.250.0.100,10.250.0.150,1h --dhcp-option=3,10.250.0.2 \
      --dhcp-option=6,10.250.0.2 --address=/internet.test/10.250.0.2 --dhcp-leasefile=/tmp/leases \
      --log-dhcp --log-facility=/tmp/dnsmasq.log'

  for c in lan1:lan trunk1:trunk; do
    n=${c%%:*}; net=${c#*:}
    $D run -d --name $P-$n --hostname $n --cap-add NET_ADMIN --cap-add NET_RAW \
       --network $P-$net $IMG sleep infinity >/dev/null
    x $n 'apk add -q --no-cache busybox-extras >/dev/null; mkdir -p /www; echo "hello from $(hostname)" >/www/index.html'
  done
  # clients start with no address (docker IPAM addresses removed)
  x lan1 'ip -4 addr flush dev eth0; ip route flush table main'
  x trunk1 'ip -4 addr flush dev eth0; ip route flush table main'

  # Appliance
  $D create --init --name $P-fw --hostname fw --privileged --network $P-wan -v "$REPO:/src:ro" $IMG sleep infinity >/dev/null
  $D network connect $P-lan $P-fw
  $D network connect $P-trunk $P-fw
  $D start $P-fw >/dev/null
  WAN=$(x fw "ip -o -4 addr | awk '/10\.250\./{print \$2}'")
  LAN=$(x fw "ip -o -4 addr | awk '/10\.251\./{print \$2}'")
  TRUNK=$(x fw "ip -o -4 addr | awk '/10\.252\./{print \$2}'")
  echo "fw NICs: wan=$WAN lan=$LAN trunk=$TRUNK"
  x fw "apk add -q --no-cache openrc >/dev/null
    mkdir -p /run/openrc && touch /run/openrc/softlevel
    umount /etc/resolv.conf 2>/dev/null; echo 'nameserver 10.250.0.2' >/etc/resolv.conf
    # fresh Alpine: WAN on DHCP, other NICs unconfigured
    for i in \$(ls /sys/class/net); do [ \$i = lo ] || ip -4 addr flush dev \$i; done
    ip route flush table main
    printf 'auto lo\niface lo inet loopback\n\nauto $WAN\niface $WAN inet dhcp\n' >/etc/network/interfaces
    apk add -q --no-cache ifupdown-ng >/dev/null 2>&1 || true
    ifup -a >/dev/null 2>&1"
  x fw "ip -br addr; ip route"
  x fw "cd /src && ./install.sh --admin-user admin" | tee /tmp/$P-install.log
  x fw "printf '%s\n' 'labpass123' | htpasswd -i /etc/litefwm/htpasswd admin >/dev/null 2>&1"
  printf 'WAN=%s\nLAN=%s\nTRUNK=%s\n' "$WAN" "$LAN" "$TRUNK" >/tmp/$P.env
}

down() {
  for c in fw isp lan1 trunk1; do $D rm -f $P-$c >/dev/null 2>&1; done
  for n in wan lan trunk; do $D network rm $P-$n >/dev/null 2>&1; done
  true
}

case "${1:-}" in
  up) up;;
  down) down;;
  test) shift; exec "$REPO/tests/lab-test.sh" "$@";;
  ui) . /tmp/$P.env
      FWIP=$(x fw "ip -4 -o addr show dev $WAN | awk '{print \$4}' | cut -d/ -f1 | head -n1")
      API=http://$FWIP LAN=$LAN TRUNK=$TRUNK exec node "$REPO/tests/ui-test.js";;
  *) sed -n '2,13p' "$0"; exit 2;;
esac
