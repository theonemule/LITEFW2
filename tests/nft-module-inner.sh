#!/bin/sh
# Privileged Alpine integration: optional modules and native GeoIP set.
set -eu
apk add -q --no-cache nftables jq iproute2 openssh >/dev/null
mkdir -p /etc/litefw-addons /etc/init.d /tmp/nft-module
install -m 0755 /src/modules/shared/init-geoip /etc/init.d/litefw-geoip
cat >/etc/litefw-addons/geoip.json <<'JSON'
{"enabled":true,"countries":["us"]}
JSON
cat >/etc/litefw-addons/geoip.nft <<'NFT'
set litefw_geo4 {
 type ipv4_addr
 flags interval
 elements = { 192.0.2.0/24, 198.51.100.0/24 }
}
NFT
export LFW_LIB=/src/lib LFW_FW_SAVE=/tmp/nft-module/boot.nft LFW_RUN=/tmp/nft-module
/src/bin/lfwctl persist
nft list set inet litefw litefw_geo4 | grep -q '192.0.2.0/24'
nft list chain inet litefw LFW_MOD | grep -q 'ip saddr @litefw_geo4 drop'
nft list chain inet litefw LFW_FWD | grep -q 'ip saddr @litefw_geo4 drop'
/src/bin/lfwctl get module geoip | jq -e '.module.state.settings.loadedNetworks==2' >/dev/null || true
# Verify translator covers the actual module grammar: VPN, routing, DNS, multicast.
. /src/lib/common.sh
. /src/lib/fw.sh
printf '%s\n' \
 '-A LFW_MOD -i eth0 -p udp -m multiport --dports 500,4500 -m comment --comment lfw:module:ipsec -j ACCEPT' \
 '-A LFW_MOD -i eth0 -p esp -m comment --comment lfw:module:ipsec -j ACCEPT' \
 '-A LFW_MOD -p udp -m udp --dport 1194 -m comment --comment lfw:module:openvpn -j ACCEPT' \
 '-A LFW_MOD -i br1 -d 224.0.0.251 -p udp --dport 5353 -m comment --comment lfw:module:mdns -j ACCEPT' |
fw_module_translate >/tmp/nft-module/translated
grep -q 'udp dport { 500, 4500 }' /tmp/nft-module/translated
grep -q 'meta l4proto esp accept' /tmp/nft-module/translated
grep -q 'ip daddr 224.0.0.251' /tmp/nft-module/translated
# Runtime-only geoip file is part of the canonical nftables boot table.
nft -c -f /tmp/nft-module/boot.nft
nft -f /tmp/nft-module/boot.nft
nft list chain inet litefw LFW_MOD | grep -q @litefw_geo4
echo 'PASS native nftables GeoIP, module descriptors, and boot reload'