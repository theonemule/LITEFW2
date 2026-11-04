#!/bin/sh
# Executed only within a disposable Alpine 3.24 container.
set -eu
cd /workspace
apk add --no-cache jq tailscale tailscale-openrc openrc >/dev/null
test -f /etc/init.d/tailscale
LFW_MODULE_CONFIG_DIR=/tmp/litefw-test-tailscale
export LFW_MODULE_CONFIG_DIR
modules/tailscale/module.sh installed
test -z "$(modules/tailscale/module.sh firewall)"
test ! -e "$LFW_MODULE_CONFIG_DIR/tailscale.json"
echo "PASS native Tailscale Alpine packages detected without joining a tailnet"

cat >/tmp/tailscale-valid.json <<'JSON'
{"hostname":"litefw-edge","acceptRoutes":false,"advertiseRoutes":["10.0.1.0/24"]}
JSON
modules/tailscale/module.sh validate /tmp/tailscale-valid.json
modules/tailscale/module.sh configure /tmp/tailscale-valid.json >/tmp/tailscale-snapshot.json
jq -e '.settings.advertiseRoutes==["10.0.1.0/24"] and .settings.acceptRoutes==false' /tmp/tailscale-snapshot.json >/dev/null
test "$(stat -c %a "$LFW_MODULE_CONFIG_DIR/tailscale.json")" = 600
for request in \
  '{"acceptRoutes":"yes","advertiseRoutes":[]}' \
  '{"acceptRoutes":false,"advertiseRoutes":["10.0.1.999/24"]}' \
  '{"acceptRoutes":false,"advertiseRoutes":["10.0.1.0/24;true"]}'; do
  printf '%s\n' "$request" >/tmp/tailscale-bad.json
  if modules/tailscale/module.sh validate /tmp/tailscale-bad.json >/dev/null 2>&1; then
    echo "FAIL invalid configuration accepted"; exit 1
  fi
done
echo "PASS valid subnet configuration, rejection of malformed routes, and root-only settings"

mkdir -p /tmp/litefw-test-bin
cat >/tmp/litefw-test-bin/rc-service <<'SVC'
#!/bin/sh
case "$1:$2" in
  tailscale:status|tailscale:start|tailscale:stop|tailscale:restart) exit 0;;
  *) echo 'Unexpected OpenRC service request' >&2; exit 1;;
esac
SVC
cat >/tmp/litefw-test-bin/rc-update <<'RC'
#!/bin/sh
case "$1:$2:$3" in
  add:tailscale:default|del:tailscale:default) exit 0;;
  *) echo 'Unexpected OpenRC update' >&2; exit 1;;
esac
RC
cat >/tmp/litefw-test-bin/tailscale <<'FAKE'
#!/bin/sh
case "$1" in
 status)
  printf '%s\n' '{"BackendState":"Running","Self":{"TailscaleIPs":["100.101.102.103"],"Online":true},"CurrentTailnet":{"Name":"example.ts.net"}}'
  ;;
 up)
  printf '%s\n' "$@" | sed '/auth-key/d' >/tmp/tailscale-flags
  for f in '--accept-dns=false' '--accept-routes=false' '--netfilter-mode=off' '--advertise-exit-node=false' '--advertise-routes=10.0.1.0/24'; do
    printf '%s\n' "$@" | grep -Fxq -- "$f" || exit 1
  done
  for arg in "$@"; do
    case "$arg" in
      --auth-key=file:*)
        file=${arg#--auth-key=file:}
        test "$(stat -c %a "$file")" = 600
        grep -Eq '^tskey-auth-[A-Za-z0-9_-]{16,250}$' "$file"
        printf '%s\n' "$file" >/tmp/tailscale-key-path
        ;;
    esac
  done
  test -s /tmp/tailscale-key-path
  ;;
 down) echo disconnected >/tmp/tailscale-down;;
 *) exit 1;;
esac
FAKE
chmod +x /tmp/litefw-test-bin/*
export PATH=/tmp/litefw-test-bin:$PATH
printf '%s\n' '{"authKey":"tskey-auth-EXAMPLETESTKEY000001"}' >/tmp/tailscale-connect.json
modules/tailscale/module.sh connect /tmp/tailscale-connect.json >/tmp/tailscale-connected.json
test ! -e "$(cat /tmp/tailscale-key-path)"
jq -e '.backendState=="Running" and .online==true and .addresses==["100.101.102.103"]' /tmp/tailscale-connected.json >/dev/null
! grep -Fq 'tskey-auth-' /tmp/tailscale-connected.json
! grep -Fq 'tskey-auth-' "$LFW_MODULE_CONFIG_DIR/tailscale.json"
echo "PASS explicit Tailscale connect with protected ephemeral key and conservative DNS/firewall/routes"
modules/tailscale/module.sh disconnect >/dev/null
test -s /tmp/tailscale-down
echo "PASS explicit disconnect"
