#!/bin/sh
# Explicit legacy-iptable migration refusal and compatible runtime update.
set -eu
apk add --no-cache -q jq iproute2 iptables nftables dnsmasq lighttpd curl >/dev/null
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
  # A live legacy iptables policy must never be silently replaced by
  # nftables during an application-only update.
  mkdir -p /etc/init.d; : > /etc/init.d/iptables
  iptables -N LFW_MGMT
  iptables -A INPUT -j LFW_MGMT
  if sh /src/bin/litefw-upgrade /tmp/upgrade.tar.gz >/tmp/unsafe-migration.log 2>&1; then
    echo 'FAIL: runtime upgrade silently accepted active legacy iptables' >&2; exit 1
  fi
  grep -q 'Runtime-only iptables -> nftables upgrades are prohibited' /tmp/unsafe-migration.log
  test "$(cat /usr/lib/litefwm/VERSION)" = 2.2.11
  iptables -D INPUT -j LFW_MGMT
  iptables -X LFW_MGMT
  echo 'PASS active legacy iptables policy blocks unsafe runtime-only migration'
  # Even a stopped legacy iptables installation must require an explicit
  # backend migration instead of installing new nftables code on reboot.
  cp /usr/lib/litefwm/fw.sh /tmp/installed-nft-fw.sh
  printf '#!/bin/sh\n# legacy iptables implementation\n' >/usr/lib/litefwm/fw.sh
  if sh /src/bin/litefw-upgrade /tmp/upgrade.tar.gz >/tmp/legacy-backend.log 2>&1; then
    echo 'FAIL: inactive legacy firewall backend upgraded silently' >&2; exit 1
  fi
  grep -q 'requires a console-backed nftables migration' /tmp/legacy-backend.log
  test "$(cat /usr/lib/litefwm/VERSION)" = 2.2.11
  cp /tmp/installed-nft-fw.sh /usr/lib/litefwm/fw.sh
  echo 'PASS inactive legacy firewall backend still blocks unsafe cutover'
  echo '# nftables persisted' >/etc/nftables.nft
  mkdir -p /etc/litefw-addons
  echo '# geoip persisted' >/etc/litefw-addons/geoip.nft
  # Real 2.2.11 -> current version application upgrade on a clean appliance.
  sh /src/bin/litefw-upgrade /tmp/upgrade.tar.gz
  test "$(cat /usr/lib/litefwm/VERSION)" = "$(cat /src/VERSION)"
  test -x /usr/sbin/litefw-upgrade
  test -s /usr/share/litefwm/www/dns-presets.js
  test -s /etc/dnsmasq.hosts.d/bc-24-11-98-a7-a4
  grep -q 'nftables persisted' /etc/nftables.nft
  grep -q 'geoip persisted' /etc/litefw-addons/geoip.nft
  test "$(ls /root/litefw-upgrade-backups/config-2.2.11-*.tar.gz | wc -l)" = 1
  tar tzf /root/litefw-upgrade-backups/config-2.2.11-*.tar.gz | grep -Fxq etc/nftables.nft
  tar tzf /root/litefw-upgrade-backups/config-2.2.11-*.tar.gz | grep -Fxq etc/litefw-addons/geoip.nft
  grep -q preserved /var/bind/litefwm/blaize.net.zone
  grep -q preserved /etc/iptables/rules-save
  grep -q preserved /etc/network/interfaces
  grep -q preserved /etc/dnsmasq.d/10-dns.conf
  test ! -e /etc/dnsmasq.d/30-dhcp-eth1.conf
  test ! -e /etc/litefwm/dhcp-scopes/eth1.json
  test "$(ls /root/litefw-upgrade-backups/runtime-2.2.11-*.tar.gz | wc -l)" = 1
  grep -q "^op_upgrade_install()" /usr/lib/litefwm/sys.sh
  echo "PASS in-place runtime upgrade preserves configs, no DHCP scopes"
