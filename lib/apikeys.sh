#!/bin/sh
# API tokens are one-time 256-bit secrets. Store only digests, never plaintext.
LFW_API_KEYS_FILE=${LFW_API_KEYS_FILE:-/etc/litefwm/api-keys.json}
apikey_random() { head -c "$1" /dev/urandom | od -An -v -tx1 | tr -d '[:space:]'; }
apikey_hash() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
apikey_file_check() { [ ! -L "$LFW_API_KEYS_FILE" ] || die 'API key registry must not be a symlink'; }
apikey_current() {
  apikey_file_check
  if [ -f "$LFW_API_KEYS_FILE" ]; then
    jq -e 'type=="object" and (.keys|type=="array")' "$LFW_API_KEYS_FILE" >/dev/null || die 'Invalid API key registry'
    cat "$LFW_API_KEYS_FILE"
  else printf '{"keys":[]}\n'; fi
}
apikey_save() {
  apikey_file_check
  local dir temp
  dir=$(dirname "$LFW_API_KEYS_FILE")
  if [ ! -d "$dir" ]; then install -d -m 0750 "$dir"; fi
  temp=$(mktemp "$dir/.api-keys.XXXXXX") || die 'Cannot allocate API key registry'
  chmod 0600 "$temp"
  cat >"$temp"
  jq -e '(.keys|type=="array" and length<=100) and all(.keys[]; has("sha256") and has("id"))' "$temp" >/dev/null ||
    { rm -f "$temp"; die 'Malformed API key registry'; }
  mv "$temp" "$LFW_API_KEYS_FILE"
}
apikey_list() {
  local now
  now=$(date -u +%s)
  apikey_current | jq --argjson now "$now" '
    {apiKeys:[.keys[] | {id,name,scope,createdAt,expiresAt,
      expired:(.expiresAt!=null and .expiresAt<=$now)}]}'
}
# Existing LiteFW 2.2.22 appliances only receive bin/lib/cgi/www in runtime
# upgrades. On the first Basic-authenticated key creation, migrate the existing
# LiteFW Lighttpd config without resetting its port or password configuration.
# The web listener stays LAN-only; config is validated before replacing.
apikey_enable_http() {
  local config main tmp backup
  config=${LFW_API_LIGHTTPD_CONF:-/etc/lighttpd/litefwm.conf}
  main=${LFW_API_LIGHTTPD_MAIN:-/etc/lighttpd/lighttpd.conf}
  [ -r "$config" ] || return 0  # offline unit tests with no Lighttpd
  if grep -Fq '$REQUEST_HEADER["X-API-Key"]' "$config"; then return 0; fi
  grep -Eq '^auth\.require = \( "/" => ' "$config" ||
    die 'Cannot add API key authentication: unknown Lighttpd Basic authentication configuration'
  [ ! -L "$config" ] || die 'Refusing symlinked management configuration'
  tmp=$(mktemp "$(dirname "$config")/.litefw-api.XXXXXX") ||
    die 'Cannot stage Lighttpd authentication configuration'
  backup="$config.before-api-keys"
  # Keep exactly the existing Basic policy, with an exception only for
  # syntactically well-formed API-key headers on API paths.
  awk '
    /^auth\.require = \( "\/" => / {
      print
      print "$HTTP[\"url\"] =~ \"^/api(/|[.]cgi/)\" {"
      print "  $REQUEST_HEADER[\"X-API-Key\"] =~ \"^lfw_sk_[a-f0-9]{64}$\" {"
      print "    auth.require = ()"
      print "  }"
      print "}"
      next
    }
    {print}
  ' "$config" >"$tmp"
  chmod 0644 "$tmp"
  cp -p "$config" "$backup" || { rm -f "$tmp"; die 'Could not back up existing authentication config'; }
  mv "$tmp" "$config"
  if ! lighttpd -tt -f "$main" >/dev/null 2>&1; then
    cp -p "$backup" "$config" || die 'Critical: unable to restore Lighttpd Basic auth after rejected configuration'
    die 'Lighttpd rejected API key authentication; original Basic authentication restored'
  fi
  # This operation is invoked by a Basic-authenticated HTTP request. Defer
  # restart until after CGI has responded, avoiding a dropped key response.
  if [ "${LFW_API_SKIP_WEB_RESTART:-no}" != yes ]; then
    ( sleep 2; rc-service lighttpd restart >/dev/null 2>&1 )       </dev/null >/dev/null 2>&1 &
  fi
}
op_apikey_create() {
  local name scope days count key id hash now exp registry
  name=$(jq -r '.name // ""' "$BODY")
  scope=$(jq -r '.scope // "read"' "$BODY")
  days=$(jq -r '.expiresInDays // 90' "$BODY")
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$' ||
    die 'Key name must be 1–64 letters, numbers, spaces, periods, underscores or dashes'
  case "$scope" in read|admin) :;; *) die 'API key scope must be read or admin';; esac
  case "$days" in 0|7|30|90|365) :;; *) die 'Choose an expiry of 7, 30, 90, 365 days or 0 for never';; esac
  apikey_enable_http
  registry=$(apikey_current)
  count=$(printf '%s' "$registry" | jq '.keys|length')
  [ "$count" -lt 100 ] || die 'Maximum 100 API keys'
  key="lfw_sk_$(apikey_random 32)"
  id=$(apikey_random 10)
  hash=$(apikey_hash "$key")
  now=$(date -u +%s)
  if [ "$days" = 0 ]; then exp=null; else exp=$((now+days*86400)); fi
  printf '%s' "$registry" | jq --arg id "$id" --arg name "$name" \
    --arg scope "$scope" --arg hash "$hash" \
    --argjson now "$now" --argjson exp "$exp" '
    .keys += [{id:$id,name:$name,scope:$scope,sha256:$hash,createdAt:$now,expiresAt:$exp}]' | apikey_save
  jq -n --arg key "$key" --arg id "$id" --arg name "$name" --arg scope "$scope" \
    --argjson expiresAt "$exp" '{id:$id,name:$name,scope:$scope,expiresAt:$expiresAt,key:$key}' >"$RESULT"
  log_op "apikey.create id=$id scope=$scope"
}
op_apikey_revoke() {
  local id registry present
  id=$(jq -r '.id // ""' "$BODY")
  printf '%s' "$id" | grep -Eq '^[a-f0-9]{20}$' || die 'Invalid key identifier'
  registry=$(apikey_current)
  present=$(printf '%s' "$registry" | jq --arg id "$id" '[.keys[]|select(.id==$id)]|length')
  [ "$present" -eq 1 ] || die 'API key not found'
  printf '%s' "$registry" | jq --arg id "$id" '.keys|=map(select(.id!=$id))' | apikey_save
  printf '{"revoked":true}\n' >"$RESULT"
  log_op "apikey.revoke id=$id"
}
apikey_verify() {
  local token digest now
  IFS= read -r token || :
  [ "${#token}" -eq 71 ] || return 1
  printf '%s' "$token" | grep -Eq '^lfw_sk_[a-f0-9]{64}$' || return 1
  digest=$(apikey_hash "$token")
  now=$(date -u +%s)
  apikey_current | jq -e --arg hash "$digest" --argjson now "$now" '
    [.keys[]|select(.sha256==$hash and (.expiresAt==null or .expiresAt>$now))
      | {id,name,scope}] | if length==1 then .[0] else empty end' || return 1
}
