#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

for m in bind openvpn ddns dnsmasq; do
  test -x "modules/$m/module.sh"
  test -x "modules/$m/install.sh"
  test -x "modules/$m/uninstall.sh"
done
test -r modules/manifest.json
jq -e '.schemaVersion==1 and (.modules|length)==4 and
  (any(.modules[]; .id=="dnsmasq" and .core==true)) and
  (any(.modules[]; .id=="ddns" and (.packages|index("inadyn-openrc")!=null)))' modules/manifest.json >/dev/null
grep -q 'module_manifest_entry' lib/modules.sh
grep -q '"$_mf" installed' lib/modules.sh
grep -q '"$_installer"' lib/modules.sh
test -r lib/modules.sh
test -r lib/module-compat.sh

# Optional packages are not part of the base appliance.
base_apk=$(grep '^apk add --no-cache ' install.sh | head -1)
for p in bind bind-tools bind-openrc openvpn openvpn-openrc easy-rsa inadyn inadyn-openrc; do
  ! printf '%s\n' "$base_apk" | grep -Eq "(^|[[:space:]])$p([[:space:]]|$)"
done
grep -q 'cp -R "$BASE/modules" /usr/lib/litefwm/modules' install.sh

# There is no module state registry. Installed/configured state is discovered live.
! grep -RqsE 'modules\.json|module-registry|/etc/litefwm/modules' bin lib modules install.sh
grep -q '"$_mf" installed' lib/modules.sh
grep -q '"$_mf" snapshot' lib/modules.sh
for op in module_install module_remove bind_settings bind_zoneadd bind_recordadd openvpn_server openvpn_clientadd openvpn_profile ddns_configure ddns_force; do
  grep -q "^op_${op}()" lib/modules.sh
done

# BIND owns native named files, validates zones, and disables only dnsmasq DNS.
grep -q 'CONF=/etc/bind/named.conf' modules/bind/module.sh
grep -q 'ZONE_DIR=/var/bind/litefwm' modules/bind/module.sh
grep -q 'Open recursion is not allowed' modules/bind/module.sh
grep -q "'port=0'" modules/bind/module.sh
grep -q 'named-checkzone' modules/bind/module.sh
grep -q 'primaryNsAddress' www/app.js
grep -q 'jget primaryNsAddress' lib/modules.sh

# OpenVPN owns its PKI and TUN interface. The TUN interface is live-visible to
# firewall rules but deliberately excluded from ifupdown persistence.
grep -q 'CONF=/etc/openvpn/litefwm.conf' modules/openvpn/module.sh
grep -q "grep -Eq '\^tun" modules/openvpn/module.sh
grep -q 'tls-crypt' modules/openvpn/module.sh
grep -q 'EASYRSA' modules/openvpn/module.sh
grep -q 'client-profile' modules/openvpn/module.sh
grep -q 'ovpn.*echo vpn' lib/net.sh
grep -q 'kind == "physical" or .kind == "bridge" or .kind == "vlan"' lib/persist.jq

# DDNS uses inadyn native configuration and never exposes the credential in state.
grep -q 'LFW_INADYN_CONF' modules/ddns/module.sh
grep -q 'credentialConfigured' modules/ddns/module.sh
! grep -q 'password:$' modules/ddns/module.sh
grep -q 'chmod 0640 "$CONF"' modules/ddns/module.sh
grep -q 'inadyn --check-config' modules/ddns/module.sh
grep -Fq '[ -f /etc/init.d/inadyn ]' modules/ddns/module.sh
grep -q 'Dynamic DNS installation failed' modules/ddns/module.sh
grep -q 'op_ddns_cfcheck()' lib/modules.sh
grep -q 'op_ddns_cfupdate()' lib/modules.sh
grep -q 'cloudflare-check)' modules/ddns/module.sh
grep -q 'Cloudflare DNS (pfSense migration)' www/app.js
grep -q 'Installer exited but' lib/modules.sh
grep -q 'DNSMasq provides' modules/dnsmasq/module.sh
grep -q 'zone-records)' modules/bind/module.sh
grep -q 'op_bind_zonerecords()' lib/modules.sh
grep -q 'op_bind_recordchange()' lib/modules.sh

# Module firewall openings are derived into their own chain on every sync.
grep -q 'LFW_MOD' lib/fw.sh
grep -q 'LFW_MOD' modules/bind/module.sh
grep -q 'LFW_MOD' modules/openvpn/module.sh
grep -q 'module_firewall_rules' lib/fw.sh

# UI exposes install/config/remove and service-specific configuration.
grep -q 'href="#modules"' www/index.html
grep -q 'views.modules' www/app.js
grep -q 'function bindPanel()' www/app.js
grep -q 'function openvpnPanel()' www/app.js
grep -q 'function ddnsPanel()' www/app.js
grep -q 'openvpnGetProfile' www/app.js
for module in bind ddns openvpn dnsmasq; do
  grep -Fq "views['module-$module']" www/app.js
done
grep -q 'function bindManageZoneRecords' www/app.js

echo "module contract ok"
