#!/bin/sh
# Verify the console root-SSH emergency access can be enabled and disabled
# immediately, without reboot, and that it listens on LAN only.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/ssh" "$tmp/net/eth1" "$tmp/net/eth5"
printf 'lfw:role=lan;name=Main\n' >"$tmp/net/eth1/ifalias"
printf 'lfw:role=wan;name=WAN\n' >"$tmp/net/eth5/ifalias"
cat >"$tmp/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
/usr/bin/id "$@"
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  *'dev eth1 scope global'*) echo '2: eth1 inet 10.0.1.199/24 brd 10.0.1.255 scope global eth1' ;;
  *'dev eth5 scope global'*) echo '5: eth5 inet 203.0.113.5/24 brd 203.0.113.255 scope global eth5' ;;
esac
EOF
cat >"$tmp/bin/passwd" <<'EOF'
#!/bin/sh
echo "$*" >>"$TEST_LOG"
if [ -f "$TEST_FAIL_PASSWD" ]; then exit 1; fi
EOF
cat >"$tmp/bin/sshd" <<'EOF'
#!/bin/sh
[ "$1" = -t ] || exit 1
[ ! -f "$TEST_BAD_CONFIG" ] || exit 1
if [ -e "$LITEFW_TEMP_SSH_CONF" ]; then
  grep -Fxq 'PermitRootLogin yes' "$LITEFW_TEMP_SSH_CONF" || exit 1
  grep -Fxq 'PasswordAuthentication yes' "$LITEFW_TEMP_SSH_CONF" || exit 1
  grep -Fxq 'PermitEmptyPasswords no' "$LITEFW_TEMP_SSH_CONF" || exit 1
fi
EOF
cat >"$tmp/bin/rc-service" <<'EOF'
#!/bin/sh
echo "$*" >>"$TEST_LOG"
EOF
cat >"$tmp/bin/rc-update" <<'EOF'
#!/bin/sh
echo "$*" >>"$TEST_LOG"
EOF
chmod +x "$tmp/bin/"*
export LITEFW_PATH="$tmp/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LITEFW_SYS_NET="$tmp/net"
export LITEFW_TEMP_SSH_CONF="$tmp/ssh/00-litefw-temporary-root.conf"
export TEST_LOG="$tmp/actions.log"
export TEST_BAD_CONFIG="$tmp/bad-config"
export TEST_FAIL_PASSWD="$tmp/fail-passwd"
: >"$TEST_LOG"
./bin/litefw-ssh-access status >"$tmp/status" && { echo 'FAIL: initially enabled'; exit 1; }
grep -Fxq disabled "$tmp/status"
./bin/litefw-ssh-access enable >"$tmp/enable"
grep -Fxq 'ListenAddress 10.0.1.199' "$LITEFW_TEMP_SSH_CONF"
! grep -q '203.0.113' "$LITEFW_TEMP_SSH_CONF"
./bin/litefw-ssh-access status | grep -q '^enabled: 10.0.1.199$'
grep -Fxq 'root' "$TEST_LOG"
grep -Fxq 'sshd restart' "$TEST_LOG"
grep -q 'DISABLE when finished' "$tmp/enable"
echo 'PASS: password SSH enabled on LAN only, notice included'
./bin/litefw-ssh-access disable >"$tmp/disable"
test ! -e "$LITEFW_TEMP_SSH_CONF"
./bin/litefw-ssh-access status | grep -Fxq disabled
grep -Fxq -- '-d root' "$TEST_LOG"
grep -q 'No reboot required' "$tmp/disable"
test "$(grep -c '^sshd restart$' "$TEST_LOG")" -eq 2
echo 'PASS: key-only policy restored immediately and password cleared without reboot'
touch "$TEST_FAIL_PASSWD"
if ./bin/litefw-ssh-access enable >"$tmp/failure" 2>&1; then
  echo 'FAIL: password command failure accepted' >&2; exit 1
fi
test ! -e "$LITEFW_TEMP_SSH_CONF"
rm "$TEST_FAIL_PASSWD"
touch "$TEST_BAD_CONFIG"
if ./bin/litefw-ssh-access enable >"$tmp/bad" 2>&1; then
  echo 'FAIL: invalid sshd configuration accepted' >&2; exit 1
fi
test ! -e "$LITEFW_TEMP_SSH_CONF"
echo 'PASS: password/SSHD validation failures do not expose root password SSH'
