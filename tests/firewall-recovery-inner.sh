#!/bin/sh
set -eu
apk add -q --no-cache nftables jq >/dev/null
mkdir -p /run/litefwm
cat >/tmp/recovery-test.nft <<'NFT'
table inet litefw {
  chain INPUT {
    type filter hook input priority filter; policy drop;
    tcp dport 22 drop comment "test:deny-ssh"
  }
  chain FORWARD {
    type filter hook forward priority filter; policy drop;
  }
  chain PREROUTING {
    type nat hook prerouting priority dstnat; policy accept;
  }
  chain POSTROUTING {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "eth0" masquerade
  }
}
NFT
nft -f /tmp/recovery-test.nft
nft list table inet litefw >/etc/nftables.nft
before=$(sha256sum /etc/nftables.nft | awk '{print $1}')
if /src/bin/litefw-recovery status >/dev/null; then echo 'Unexpected bypass active'; exit 1; fi
if printf 'NO\n' | /src/bin/litefw-recovery enable >/dev/null; then echo 'FAIL: bypass without YES'; exit 1; fi
[ ! -e /run/litefwm/breakglass/snapshot ]
printf 'YES\n' | /src/bin/litefw-recovery enable
/src/bin/litefw-recovery status | grep -Fxq enabled
nft -a list chain inet litefw INPUT | grep -q 'accept # handle'
nft -a list chain inet litefw FORWARD | grep -q 'accept # handle'
nft list chain inet litefw POSTROUTING | grep -q masquerade
[ "$before" = "$(sha256sum /etc/nftables.nft | awk '{print $1}')" ]
/src/bin/litefw-recovery disable
if /src/bin/litefw-recovery status >/dev/null; then echo 'Bypass still active'; exit 1; fi
nft list chain inet litefw INPUT | grep -q 'tcp dport 22 drop'
! nft list chain inet litefw INPUT | grep -Eq '^[[:space:]]+accept$'
! nft list chain inet litefw FORWARD | grep -Eq '^[[:space:]]+accept$'
[ "$before" = "$(sha256sum /etc/nftables.nft | awk '{print $1}')" ]
echo 'PASS: native nftables console recovery, volatile bypass, original policies and NAT restored'