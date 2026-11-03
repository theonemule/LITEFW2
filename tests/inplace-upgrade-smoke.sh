#!/bin/sh
# In-place upgrade integration smoke against a disposable Alpine container.
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD":/src:ro alpine:3.24 sh -euc '
  apk add --no-cache -q jq iproute2 iptables dnsmasq lighttpd curl >/dev/null
  mkdir -p /etc/litefwm /etc/dnsmasq.d /etc/dnsmasq.hosts.d /etc/network \
    /etc/iptables /etc/bind /var/bind/litefwm /usr/lib/litefwm \
    /usr/share/litefwm/www /etc/lighttpd
  touch /etc/litefwm/installed
  cp /src/lib/* /usr/lib/litefwm/ 2>/dev/null || true
  cp -R /src/modules /usr/lib/litefwm/
  cp -R /src/www/. /usr/share/litefwm/www/
  cp /src/cgi/api.cgi /usr/lib/litefwm/cgi-does-not-matter 2>/dev/null || true
  for f in lfwctl lfw-setup litefw-admin litefw-network litefw-console litefw-web-bind litefw-ssh-access; do cp "/src/bin/$f" "/usr/sbin/$f"; chmod +x "/usr/sbin/$f"; done
  printf "2.2.11\n" >/usr/lib/litefwm/VERSION
  printf "bc:24:11:98:a7:a4,10.0.1.2\n" >/etc/dnsmasq.hosts.d/bc-24-11-98-a7-a4
  echo "zone preserved;" >/var/bind/litefwm/blaize.net.zone
  echo "# filter preserved" >/etc/iptables/rules-save
  echo "# LAN preserved" >/etc/network/interfaces
  echo "# DNS preserved" >/etc/dnsmasq.d/10-dns.conf
  echo "server.document-root = \"/usr/share/litefwm/www\"" >/etc/lighttpd/lighttpd.conf
  echo "server.port = 8089" >>/etc/lighttpd/lighttpd.conf
  tar -C /src -czf /tmp/upgrade.tar.gz VERSION bin lib modules cgi www
  # Unusable archive must be refused without modifying the installed version.
  printf "invalid" >/tmp/invalid.tar.gz
  if sh /src/bin/litefw-upgrade /tmp/invalid.tar.gz >/tmp/invalid.log 2>&1; then
    echo "FAIL: invalid archive accepted"; exit 1
  fi
  test "$(cat /usr/lib/litefwm/VERSION)" = 2.2.11
  # Real 2.2.11 -> 2.2.12 application upgrade.
  sh /src/bin/litefw-upgrade /tmp/upgrade.tar.gz
  test "$(cat /usr/lib/litefwm/VERSION)" = 2.2.12
  test -x /usr/sbin/litefw-upgrade
  test -s /usr/share/litefwm/www/dns-presets.js
  test -s /etc/dnsmasq.hosts.d/bc-24-11-98-a7-a4
  grep -q preserved /var/bind/litefwm/blaize.net.zone
  grep -q preserved /etc/iptables/rules-save
  grep -q preserved /etc/network/interfaces
  grep -q preserved /etc/dnsmasq.d/10-dns.conf
  test ! -e /etc/dnsmasq.d/30-dhcp-eth1.conf
  test ! -e /etc/litefwm/dhcp-scopes/eth1.json
  test "$(ls /root/litefw-upgrade-backups/runtime-2.2.11-*.tar.gz | wc -l)" = 1
  grep -q "^op_upgrade_install()" /usr/lib/litefwm/sys.sh
  echo "PASS in-place runtime upgrade preserves configs, no DHCP scopes"
'
