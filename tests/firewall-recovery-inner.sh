#!/bin/sh
set -eu
apk add -q --no-cache iptables jq >/dev/null
mkdir -p /etc/iptables /run/litefwm
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -A INPUT -p tcp --dport 22 -j DROP
iptables-save >/etc/iptables/rules-save
before=$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)
if /src/bin/litefw-recovery status >/dev/null; then echo 'Unexpected bypass active'; exit 1; fi
if printf 'NO\n' | /src/bin/litefw-recovery enable >/tmp/denied; then echo 'FAIL: bypass without YES'; exit 1; fi
test ! -e /run/litefwm/breakglass/snapshot
printf 'YES\n' | /src/bin/litefw-recovery enable
/src/bin/litefw-recovery status | grep -Fxq enabled
iptables -S INPUT | head -1 | grep -q '^-P INPUT DROP'
iptables -S INPUT | grep -Fxq -- '-A INPUT -j ACCEPT'
iptables -S FORWARD | grep -Fxq -- '-A FORWARD -j ACCEPT'
test "$before" = "$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)"
/src/bin/litefw-recovery disable
if /src/bin/litefw-recovery status >/dev/null; then echo 'Bypass still active'; exit 1; fi
iptables -S INPUT | grep -Fxq -- '-A INPUT -p tcp -m tcp --dport 22 -j DROP'
! iptables -S INPUT | grep -Fxq -- '-A INPUT -j ACCEPT'
! iptables -S FORWARD | grep -Fxq -- '-A FORWARD -j ACCEPT'
test "$before" = "$(sha256sum /etc/iptables/rules-save | cut -d' ' -f1)"
echo 'PASS: break-glass requires YES, restores original live rules without reboot; boot rules never bypassed'
