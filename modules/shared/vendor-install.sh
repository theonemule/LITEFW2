#!/bin/sh
# Version-pinned verified vendor artifacts for optional Alpine modules.
set -eu
mod=$1
[ -n "$mod" ] || { echo "Module required" >&2; exit 1; }
apk add --no-cache curl ca-certificates
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fetch(){
 curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 160 -o "$tmp/archive" "$1" ||
   { echo "Could not retrieve trusted $mod release" >&2; exit 1; }
 printf '%s  %s\n' "$2" "$tmp/archive" | sha256sum -c - >/dev/null ||
   { echo "SHA-256 mismatch; refusing unverified $mod binary" >&2; exit 1; }
}
case "$mod" in
 cloudflared)
   case "$(uname -m)" in
    x86_64) asset=cloudflared-linux-amd64; checksum=1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872;;
    aarch64) asset=cloudflared-linux-arm64; checksum=3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775;;
    *) echo "Unsupported Cloudflare architecture" >&2; exit 1;;
   esac
   fetch "https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/$asset" "$checksum"
   install -m 0755 "$tmp/archive" /usr/local/bin/cloudflared
   /usr/local/bin/cloudflared --version
   ;;
 crowdsec)
   [ "$(uname -m)" = x86_64 ] || { echo "CrowdSec supported on x86_64 only" >&2; exit 1; }
   apk add --no-cache ipset
   fetch "https://github.com/crowdsecurity/crowdsec/releases/download/v1.8.2/crowdsec-release.tgz" \
     6e0b2add0ff3231dca3db7146834d7fea028215b915e2da39ebe30fc9f11436f
   tar xzf "$tmp/archive" -C "$tmp" \
     crowdsec-v1.8.2/cmd/crowdsec/crowdsec crowdsec-v1.8.2/cmd/crowdsec-cli/cscli crowdsec-v1.8.2/config
   install -m 0755 "$tmp/crowdsec-v1.8.2/cmd/crowdsec/crowdsec" /usr/local/bin/crowdsec
   install -m 0755 "$tmp/crowdsec-v1.8.2/cmd/crowdsec-cli/cscli" /usr/local/bin/cscli
   mkdir -p /etc/crowdsec /var/lib/crowdsec/data /var/log/crowdsec
   if [ ! -r /etc/crowdsec/config.yaml ]; then
     cp -R "$tmp/crowdsec-v1.8.2/config/." /etc/crowdsec/
     sed -i 's/daemonize: true/daemonize: false/' /etc/crowdsec/config.yaml
     chmod 0600 /etc/crowdsec/*credentials*.yaml 2>/dev/null || true
   fi
   /usr/local/bin/cscli version
   ;;
 captive)
   [ "$(uname -m)" = x86_64 ] || { echo "openNDS source build supported on x86_64 only" >&2; exit 1; }
   apk add --no-cache build-base linux-headers libmicrohttpd-dev libmicrohttpd bash iptables iproute2
   fetch "https://github.com/openNDS/openNDS/archive/refs/tags/v11.0.0.tar.gz" \
     33940f8ef52e958cdf37fd49ca20a8140b85a096d529cf4e0122592ac24ced00
   tar xzf "$tmp/archive" -C "$tmp"
   (cd "$tmp/openNDS-11.0.0" && make -j2)
   install -m 0755 "$tmp/openNDS-11.0.0/opennds" /usr/local/bin/opennds
   install -m 0755 "$tmp/openNDS-11.0.0/ndsctl" /usr/local/bin/ndsctl
   mkdir -p /etc/opennds/htdocs/images /usr/lib/opennds
   install -m 0644 "$tmp/openNDS-11.0.0/resources/splash.css" /etc/opennds/htdocs/splash.css
   install -m 0644 "$tmp/openNDS-11.0.0/resources/splash.jpg" /etc/opennds/htdocs/images/splash.jpg
   cp -R "$tmp/openNDS-11.0.0/forward_authentication_service/libs/." /usr/lib/opennds/
   cp -R "$tmp/openNDS-11.0.0/forward_authentication_service/PreAuth/." /usr/lib/opennds/
   chmod 0755 /usr/lib/opennds/*.sh 2>/dev/null || true
   version=$(/usr/local/bin/opennds -v 2>&1 || true)
   printf '%s\n' "$version" | grep -q 'openNDS version' || { echo 'OpenNDS built binary failed version check' >&2; exit 1; }
   apk del build-base linux-headers libmicrohttpd-dev >/dev/null 2>&1 || true
   ;;
 *) echo "Unsupported vendor module $mod" >&2; exit 1;;
esac
