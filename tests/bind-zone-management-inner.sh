#!/bin/sh
set -eu
apk add -q --no-cache bind bind-tools jq >/dev/null
mkdir -p /etc/bind /var/bind/litefwm /tmp/fakebin
cat >/tmp/fakebin/rc-service <<'EOF'
#!/bin/sh
if [ "$2" = status ]; then exit 1; fi
exit 0
EOF
cat >/tmp/fakebin/rc-update <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x /tmp/fakebin/*
export PATH=/tmp/fakebin:$PATH
bind=/src/modules/bind/module.sh
: >/etc/bind/litefwm-zones.conf
# Fully validate recursive forwarder configuration with real named-checkconf.
"$bind" settings-set 127.0.0.1 127.0.0.1/32 "" true 127.0.0.1/32 9.9.9.9,1.1.1.1 only auto yes 7200 600 false
named-checkconf -z /etc/bind/named.conf
grep -Fq 'forward only;' /etc/bind/named.conf
grep -Fq 'dnssec-validation auto;' /etc/bind/named.conf
grep -Fq 'max-cache-ttl 7200;' /etc/bind/named.conf
grep -Fq 'max-ncache-ttl 600;' /etc/bind/named.conf
"$bind" snapshot | jq -e '.forwarders==["9.9.9.9","1.1.1.1"] and .forwardMode=="only" and .dnssecValidation=="auto" and .maxCacheTtl==7200' >/dev/null
echo "PASS: advanced forwarder, cache and DNSSEC settings validated by real BIND"
# Family-protection forwarders must never fall back to root recursion.
"$bind" settings-set 127.0.0.1 127.0.0.1/32 "" true 127.0.0.1/32 1.1.1.3,1.0.0.3 only auto yes 7200 600 false
named-checkconf -z /etc/bind/named.conf
grep -Fq 'forward only;' /etc/bind/named.conf
grep -Fq '1.1.1.3;' /etc/bind/named.conf
grep -Fq '1.0.0.3;' /etc/bind/named.conf
! grep -Fq '1.1.1.1;' /etc/bind/named.conf
echo "PASS: Cloudflare Family BIND forwarders retain strict forward-only policy"
cat >/tmp/newzone <<'EOF'
$TTL 3600
@ IN SOA ns1.test.lan. hostmaster.test.lan. ( 2026110201 3600 600 1209600 300 )
@ IN NS ns1.test.lan.
ns1 IN A 127.0.0.1
web IN A 10.0.1.101
EOF
"$bind" zone-write test.lan "" true </tmp/newzone >/tmp/write.json
named-checkconf -z /etc/bind/named.conf
named-checkzone test.lan /var/bind/litefwm/test.lan.zone
"$bind" snapshot | jq -e 'any(.zones[]; .name=="test.lan")' >/dev/null
sha=$("$bind" zone-source test.lan | jq -r '.sha')
test -n "$sha"
echo "PASS: new zone file created, listed and readable with checksum"
sed 's/2026110201/2026110202/;s/10.0.1.101/10.0.1.102/' /tmp/newzone >/tmp/updated
"$bind" zone-write test.lan "$sha" false </tmp/updated >/tmp/edited.json
grep -Fq 10.0.1.102 /var/bind/litefwm/test.lan.zone
test -n "$(jq -r '.backup' /tmp/edited.json)"
sha2=$("$bind" zone-source test.lan | jq -r '.sha')
[ "$sha" != "$sha2" ]
if "$bind" zone-write test.lan "$sha" false </tmp/newzone > /tmp/stale 2>&1; then
  echo "FAIL: stale editor overwrote zone"; exit 1
fi
cp /var/bind/litefwm/test.lan.zone /tmp/current
printf 'NOT A ZONE\n' >/tmp/invalid
if "$bind" zone-write test.lan "$sha2" false </tmp/invalid >/tmp/bad 2>&1; then
  echo "FAIL: invalid zone accepted"; exit 1
fi
cmp /tmp/current /var/bind/litefwm/test.lan.zone
named-checkconf -z /etc/bind/named.conf
echo "PASS: edits have version detection, backup and invalid zone rollback"
