#!/bin/sh
# Test draft retention and dnsmasq options without starting a real DHCP server.
set -eu
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD":/src:ro alpine:3.24 sh -euc '
  apk add -q --no-cache dnsmasq jq >/dev/null
  mkdir -p /tmp/litefw/dnsmasq /tmp/litefw/options
  LFW_DHCP_SETTINGS_DIR=/tmp/litefw/options
  LFW_DNSMASQ_CONF=/tmp/litefw/dnsmasq.conf
  LFW_DNSMASQ_DIR=/tmp/litefw/dnsmasq
  LFW_LOG=/tmp/litefw/log
  BODY=/tmp/litefw/body
  export LFW_DHCP_SETTINGS_DIR LFW_DNSMASQ_CONF LFW_DNSMASQ_DIR LFW_LOG BODY
  printf "conf-dir=/tmp/litefw/dnsmasq,*.conf\n" >"$LFW_DNSMASQ_CONF"
  . /src/lib/common.sh
  . /src/lib/dhcp.sh
  need_iface() { [ "$1" = eth1 ] || [ "$1" = eth2 ]; }
  role_of() { [ "$1" != eth2 ] && echo lan || echo none; }
  dhcp_running() { return 1; }
  iface_ips() { [ "$1" != eth1 ] || echo 10.0.1.199/24; }
  fw_sync() { echo fw_sync >>/tmp/litefw/actions; }
  dnsmasq_apply() { echo dnsmasq_apply >>/tmp/litefw/actions; }
  log_op() { :; }
  cat >"$BODY" <<EOF
{"interface":"eth1","enabled":false,"start":"10.0.1.100","end":"10.0.1.150","leaseTime":"24h","router":"10.0.1.1","dns":["10.0.1.199","1.1.1.1"],"domain":"home.arpa","searchDomains":["home.arpa","office.example"],"ntp":["10.0.1.100"],"wins":["10.0.1.15"],"bootFile":"pxelinux.0","nextServer":"10.0.1.20"}
EOF
  op_dhcpd_set
  test ! -e "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  test ! -e /tmp/litefw/actions
  dhcpd_all | jq -e ".eth1.enabled==false and .eth1.router==\"10.0.1.1\" and .eth1.dns==[\"10.0.1.199\",\"1.1.1.1\"] and .eth1.searchDomains[1]==\"office.example\" and .eth1.bootFile==\"pxelinux.0\"" >/dev/null
  echo "PASS: settings stored while DHCP OFF, without restarting services"
  # Enabling uses explicit action and dnsmasq-native options.
  sed -i "s/\"enabled\":false/\"enabled\":true/" "$BODY"
  op_dhcpd_set
  [ -f "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf" ]
  dnsmasq --test --conf-file="$LFW_DNSMASQ_CONF"
  grep -q "option:router,10.0.1.1" "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  grep -q "option:dns-server,10.0.1.199,1.1.1.1" "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  grep -q "option:domain-search,home.arpa,office.example" "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  grep -q "option:netbios-ns,10.0.1.15" "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  grep -q "dhcp-boot=tag:lfw_eth1,pxelinux.0,,10.0.1.20" "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  dhcpd_read eth1 | jq -e ".enabled==true and .start==\"10.0.1.100\"" >/dev/null
  echo "PASS: explicit enable produces valid gateway, DNS, search, WINS, PXE options"
  # Disabling again persists ALL settings.
  sed -i "s/\"enabled\":true/\"enabled\":false/" "$BODY"
  op_dhcpd_set
  test ! -e "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  dhcpd_read eth1 | jq -e ".enabled==false and .wins[0]==\"10.0.1.15\"" >/dev/null
  echo "PASS: disable removes server but preserves settings"
  # Unassigned interfaces also accept OFF drafts, never enabled.
  sed -i "s/\"interface\":\"eth1\"/\"interface\":\"eth2\"/" "$BODY"
  op_dhcpd_set
  test ! -e "$LFW_DNSMASQ_DIR/30-dhcp-eth2.conf"
  sed -i "s/\"enabled\":false/\"enabled\":true/" "$BODY"
  if (op_dhcpd_set) > /tmp/litefw/bad.log 2>&1; then
    echo "FAIL: DHCP allowed on unassigned eth2"; exit 1
  fi
  test ! -e "$LFW_DNSMASQ_DIR/30-dhcp-eth2.conf"
  echo "PASS: unassigned interface cannot enable DHCP"
  # Import a pre-2.2.9 live scope and preserve its settings while disabling.
  rm -f "$LFW_DHCP_SETTINGS_DIR/dhcp-scopes/eth1.json"
  cat >"$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf" <<EOF
# legacy LiteFW DHCP scope
dhcp-range=set:lfw_eth1,10.0.1.100,10.0.1.150,255.255.255.0,12h
dhcp-option=tag:lfw_eth1,option:router,10.0.1.199
dhcp-option=tag:lfw_eth1,option:dns-server,10.0.1.199,1.1.1.1
EOF
  dhcpd_read eth1 | jq -e ".enabled==true and .router==\"10.0.1.199\"" >/dev/null
  printf "{\"interface\":\"eth1\",\"enabled\":false}\n" >"$BODY"
  op_dhcpd_set
  test ! -f "$LFW_DNSMASQ_DIR/30-dhcp-eth1.conf"
  dhcpd_read eth1 | jq -e ".enabled==false and .router==\"10.0.1.199\" and .dns==[\"10.0.1.199\",\"1.1.1.1\"]" >/dev/null
  echo "PASS: legacy 2.2.8 active DHCP options imported and retained on disable"
'
