#!/bin/sh
set -eu
  apk add --no-cache lighttpd lighttpd-mod_auth apache2-utils sudo jq curl coreutils iproute2 iptables dnsmasq >/dev/null
  mkdir -p /usr/lib/litefwm/cgi /usr/lib/litefwm/modules /usr/share/litefwm /etc/litefwm /etc/lighttpd
  cp /workspace/lib/*.sh /usr/lib/litefwm/
  cp /workspace/VERSION /usr/lib/litefwm/VERSION
  cp -R /workspace/www/. /usr/share/litefwm/www/
  chmod -R a+rX /usr/share/litefwm/www
  cp /workspace/bin/lfwctl /usr/sbin/lfwctl
  cp /workspace/cgi/api.cgi /usr/lib/litefwm/cgi/api.cgi
  chmod +x /usr/sbin/lfwctl /usr/lib/litefwm/cgi/api.cgi
  cp /workspace/etc/litefwm-lighttpd.conf /etc/lighttpd/litefwm.conf
  sed -i "s/^server.port = 80/server.port = 18087/" /etc/lighttpd/litefwm.conf
  cat >/etc/lighttpd/lighttpd.conf <<EOF
server.modules = ("mod_auth", "mod_authn_file", "mod_alias", "mod_rewrite", "mod_setenv", "mod_cgi")
server.username = "lighttpd"
server.groupname = "lighttpd"
server.document-root = "/usr/share/litefwm/www"
index-file.names = ("index.html")
server.pid-file = "/run/lighttpd.pid"
server.errorlog = "/tmp/lighttpd.err"
server.bind = "127.0.0.1"
include "litefwm.conf"
EOF
  printf "%s\n" "test-password-123" | htpasswd -icB /etc/litefwm/htpasswd tester >/dev/null
  chown root:lighttpd /etc/litefwm/htpasswd
  chmod 0640 /etc/litefwm/htpasswd
  printf "lighttpd ALL=(root) NOPASSWD: /usr/sbin/lfwctl\nDefaults:lighttpd !requiretty, !syslog\n" > /etc/sudoers.d/litefwm
  chmod 0440 /etc/sudoers.d/litefwm
  lighttpd -tt -f /etc/lighttpd/lighttpd.conf || exit 1
  lighttpd -D -f /etc/lighttpd/lighttpd.conf >/tmp/lighttpd.out 2>&1 &
  pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null http://127.0.0.1:18087/ && break
    sleep 1
  done
  base=http://127.0.0.1:18087
  status() { curl -s -o /tmp/response -w "%{http_code}" "$@"; }
  [ "$(status "$base/")" = 401 ] || { echo "FAIL SPA must require Basic"; exit 1; }
  [ "$(status "$base/api/identity")" = 401 ] || { echo "FAIL missing credentials accepted"; cat /tmp/response; exit 1; }
  [ "$(status -u tester:wrong "$base/api/identity")" = 401 ] || { echo "FAIL wrong Basic password accepted"; exit 1; }
  [ "$(status -u tester:test-password-123 "$base/api/identity")" = 200 ] ||
    { echo "FAIL Basic API authentication"; cat /tmp/response; cat /tmp/lighttpd.err; cat /tmp/cgi-verify.log 2>/dev/null || :; exit 1; }
  [ "$(status -u tester:test-password-123 "$base/")" = 200 ] || { echo "FAIL SPA Basic auth"; cat /tmp/response; cat /tmp/lighttpd.err; exit 1; }
  echo "PASS lighttpd authenticates SPA and CGI supports valid HTTP Basic"

  body="{\"name\":\"CI read key\",\"scope\":\"read\",\"expiresInDays\":90}"
  [ "$(status -u tester:test-password-123 -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "$body" "$base/api/system/api-keys/create")" = 200 ] ||
    { echo "FAIL Basic key creation"; cat /tmp/response; exit 1; }
  token=$(jq -r .result.key /tmp/response)
  id=$(jq -r .result.id /tmp/response)
  [ "$(printf "%s" "$token" | wc -c)" -eq 71 ] || exit 1
  [ "$(stat -c %a /etc/litefwm/api-keys.json)" = 600 ] || exit 1
  if grep -Fq "$token" /etc/litefwm/api-keys.json; then echo "FAIL plaintext stored"; exit 1; fi
  [ "$(status -H "X-API-Key: $token" "$base/api/identity")" = 200 ] ||
    { echo "FAIL read key GET"; cat /tmp/response; exit 1; }
  [ "$(status -H "X-API-Key: $token" "$base/")" = 401 ] ||
    { echo "FAIL API key bypassed web UI Basic authentication"; exit 1; }
  [ "$(status -H "X-API-Key: $token" -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "{}" "$base/api/system/updates/check")" = 403 ] ||
    { echo "FAIL read-only key allowed mutation"; exit 1; }
  [ "$(status -H "X-API-Key: $token" "$base/api/system/api-keys")" = 403 ] ||
    { echo "FAIL key allowed management access"; exit 1; }
  [ "$(status -u tester:test-password-123 "$base/api/system/api-keys")" = 200 ] || exit 1
  jq -e --arg id "$id" ".apiKeys[]|select(.id==\$id)" /tmp/response >/dev/null
  if grep -Fq "$token" /tmp/response; then echo "FAIL list leaked token"; exit 1; fi
  [ "$(status -H "X-API-Key: lfw_sk_0000000000000000000000000000000000000000000000000000000000000000" "$base/api/identity")" = 401 ] || exit 1
  echo "PASS key creation, secret redaction, read-only scope, and admin-only key management"
  mkdir -p /tmp/lfw-cli-config
  printf '%s\n' "$token" | XDG_CONFIG_HOME=/tmp/lfw-cli-config     /workspace/bin/litefw login "$base" --api-key --allow-http >/tmp/lfw-cli-login.out
  test "$(stat -c %a /tmp/lfw-cli-config/litefw/config)" = 600
  XDG_CONFIG_HOME=/tmp/lfw-cli-config /workspace/bin/litefw whoami >/tmp/lfw-cli-whoami.out
  jq -e '.version != null and .hostname != null' /tmp/lfw-cli-whoami.out >/dev/null
  XDG_CONFIG_HOME=/tmp/lfw-cli-config /workspace/bin/litefw api >/tmp/lfw-cli-routes.out
  grep -Fq 'GET   /api/identity' /tmp/lfw-cli-routes.out
  if XDG_CONFIG_HOME=/tmp/lfw-cli-config /workspace/bin/litefw post /system/updates/check '{}' >/tmp/lfw-cli-post.out 2>&1; then
    echo 'FAIL CLI read-only key unexpectedly performed a POST' >&2; exit 1
  fi
  XDG_CONFIG_HOME=/tmp/lfw-cli-config /workspace/bin/litefw logout >/dev/null
  test ! -f /tmp/lfw-cli-config/litefw/config
  echo "PASS standalone CLI API-key login, GET, endpoint help, read-only enforcement, logout"


  revoke=$(printf "{\"id\":\"%s\"}" "$id")
  [ "$(status -u tester:test-password-123 -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "$revoke" "$base/api/system/api-keys/revoke")" = 200 ] ||
    { echo "FAIL revocation"; cat /tmp/response; exit 1; }
  [ "$(status -H "X-API-Key: $token" "$base/api/identity")" = 401 ] || { echo "FAIL revoked key still authorized"; exit 1; }
  echo "PASS revoked key immediately rejected"
  printf '%s\n' "test-password-123" | XDG_CONFIG_HOME=/tmp/lfw-cli-config     /workspace/bin/litefw login "$base" --basic tester --allow-http >/dev/null
  XDG_CONFIG_HOME=/tmp/lfw-cli-config /workspace/bin/litefw get /system/api-keys >/tmp/lfw-cli-basic.out
  jq -e '.apiKeys|type=="array"' /tmp/lfw-cli-basic.out >/dev/null
  XDG_CONFIG_HOME=/tmp/lfw-cli-config /workspace/bin/litefw logout >/dev/null
  echo "PASS standalone CLI Basic login works and can list API key metadata"


  body="{\"name\":\"CI admin key\",\"scope\":\"admin\",\"expiresInDays\":7}"
  [ "$(status -u tester:test-password-123 -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "$body" "$base/api/system/api-keys/create")" = 200 ] || exit 1
  token=$(jq -r .result.key /tmp/response)
  [ "$(status -H "X-API-Key: $token" "$base/api/identity")" = 200 ] || exit 1
  [ "$(status -H "X-API-Key: $token" -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "{}" "$base/api/system/api-keys/create")" = 403 ] || exit 1
  [ "$(status -H "X-API-Key: $token" -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "{}" "$base/api/op/apikey.create")" = 403 ] ||
    { echo "FAIL legacy operation bypassed Basic-only key management"; exit 1; }
  [ "$(status -H "X-API-Key: $token" -H "X-LiteFWM: 1" -H "Content-Type: application/json" -d "{}" "$base/api/modules/nosuchmodule/configure")" = 400 ] ||
    { echo "FAIL administrator key did not reach module operation validation"; exit 1; }
  echo "PASS admin key can reach mutation handlers but cannot bypass Basic-only paths"
  # Expire it in the test registry; request must now be 401.
  jq ".keys[0].expiresAt=1" /etc/litefwm/api-keys.json >/tmp/keys
  install -m 0600 /tmp/keys /etc/litefwm/api-keys.json
  [ "$(status -H "X-API-Key: $token" "$base/api/identity")" = 401 ] || exit 1
  echo "PASS administrator key authenticates, cannot mint keys, expiry enforced"
  # Upgrade compatibility: migrate the exact legacy Basic-only config
  # without resetting userfile, port or exposing the static SPA.
  sed '/^\$HTTP\["url"\]/,/^}/d' /etc/lighttpd/litefwm.conf >/etc/lighttpd/litefwm-old.conf
  sed 's/include "litefwm.conf"/include "litefwm-old.conf"/' /etc/lighttpd/lighttpd.conf >/etc/lighttpd/legacy-test.conf
  lighttpd -tt -f /etc/lighttpd/legacy-test.conf
  test "$(grep -c '\$REQUEST_HEADER' /etc/lighttpd/litefwm-old.conf)" = 0
  LFW_API_LIGHTTPD_CONF=/etc/lighttpd/litefwm-old.conf     LFW_API_LIGHTTPD_MAIN=/etc/lighttpd/legacy-test.conf     LFW_API_SKIP_WEB_RESTART=yes /usr/sbin/lfwctl op apikey.create     '{"name":"Legacy config migration","scope":"read","expiresInDays":7}' >/tmp/key-migrate.json
  jq -e '.ok==true' /tmp/key-migrate.json >/dev/null
  lighttpd -tt -f /etc/lighttpd/legacy-test.conf
  grep -Fq 'X-API-Key' /etc/lighttpd/litefwm-old.conf
  grep -Fq 'server.port = 18087' /etc/lighttpd/litefwm-old.conf
  grep -Fq 'auth.backend.htpasswd.userfile = "/etc/litefwm/htpasswd"' /etc/lighttpd/litefwm-old.conf
  test -s /etc/lighttpd/litefwm-old.conf.before-api-keys
  echo "PASS in-place Basic-only Lighttpd config migration with backup and syntax check"
  # Invalid replacement configuration must restore original Basic-only settings
  # and refuse to create a key.
  sed '/^\$HTTP\["url"\]/,/^}/d' /etc/lighttpd/litefwm.conf >/etc/lighttpd/legacy-bad.conf
  before=$(sha256sum /etc/lighttpd/legacy-bad.conf | awk '{print $1}')
  if LFW_API_LIGHTTPD_CONF=/etc/lighttpd/legacy-bad.conf \
     LFW_API_LIGHTTPD_MAIN=/etc/lighttpd/missing-file.conf \
     LFW_API_SKIP_WEB_RESTART=yes /usr/sbin/lfwctl op apikey.create \
     '{"name":"Must fail","scope":"read"}' >/tmp/bad-migrate.json; then
     echo "FAIL rejected Lighttpd config accepted" >&2; exit 1
  fi
  test "$before" = "$(sha256sum /etc/lighttpd/legacy-bad.conf | awk '{print $1}')"
  grep -Fq 'auth.require = (' /etc/lighttpd/legacy-bad.conf
  echo "PASS invalid Lighttpd migration rolls back without creating a credential"

