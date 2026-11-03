#!/bin/sh
# Behavioral IDS / inline IPS test with genuine Suricata NFQUEUE and IPv4 packets.
# Isolation is provided by the disposable privileged Docker network namespace.
set -eu
cd /workspace
echo 'CASE suricata/isolated-packet-path'
ip netns add lfw_ics
ip netns add lfw_isv
ip link add lfw_in type veth peer name lfw_ci
ip link set lfw_ci netns lfw_ics
ip link add lfw_out type veth peer name lfw_si
ip link set lfw_si netns lfw_isv
ip addr add 192.0.2.1/24 dev lfw_in
ip addr add 198.51.100.1/24 dev lfw_out
ip link set lfw_in up
ip link set lfw_out up
ip netns exec lfw_ics ip link set lo up
ip netns exec lfw_isv ip link set lo up
ip netns exec lfw_ics ip addr add 192.0.2.2/24 dev lfw_ci
ip netns exec lfw_isv ip addr add 198.51.100.2/24 dev lfw_si
ip netns exec lfw_ics ip link set lfw_ci up
ip netns exec lfw_isv ip link set lfw_si up
ip netns exec lfw_ics ip route add default via 192.0.2.1
ip netns exec lfw_isv ip route add default via 198.51.100.1
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -P FORWARD ACCEPT
iptables -N LFW_FWD
iptables -A FORWARD -j LFW_FWD
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
echo 'PASS simulated routed LAN/WAN packets pass before inspection'

echo 'CASE suricata/signed-synthetic-detection-rule'
mkdir -p /var/lib/suricata/rules /var/log/suricata /etc/conf.d
# Only this disposable container gets the synthetic rule. No feed is downloaded.
cat >/var/lib/suricata/rules/suricata.rules <<'RULE'
drop icmp 192.0.2.2 any -> 198.51.100.2 any (msg:"LiteFW simulated IPS block"; sid:9900101; rev:1;)
RULE
grep -q '^[[:space:]]*rule-files:' /etc/suricata/suricata.yaml
grep -q 'suricata.rules' /etc/suricata/suricata.yaml
suricata -T -c /etc/suricata/suricata.yaml >/tmp/lfw-suricata-validate.log 2>&1 || {
  cat /tmp/lfw-suricata-validate.log >&2; exit 1;
}
# In this non-booted Docker container we launch the real Suricata binary
# directly and emulate ONLY OpenRC's 'status' query, keyed to its real PID.
# On an actual appliance, OpenRC owns the process lifecycle.
mkdir -p /tmp/lfw-bin
cat >/tmp/lfw-bin/rc-service <<'SH'
#!/bin/sh
[ "$1" = litefw-suricata ] && [ "$2" = status ] || exit 1
test -s /tmp/lfw-suricata.pid && kill -0 "$(cat /tmp/lfw-suricata.pid)" 2>/dev/null
SH
chmod 0755 /tmp/lfw-bin/rc-service
export PATH="/tmp/lfw-bin:$PATH"
suricata_start() {
  mode=$1
  rm -f /tmp/lfw-suricata.pid
  if [ "$mode" = ids ]; then
    suricata -D -i lfw_in -c /etc/suricata/suricata.yaml       -l /var/log/suricata --pidfile /tmp/lfw-suricata.pid >/tmp/lfw-suricata-start.log 2>&1
  else
    suricata -D -q 0 -c /etc/suricata/suricata.yaml       -l /var/log/suricata --pidfile /tmp/lfw-suricata.pid >/tmp/lfw-suricata-start.log 2>&1
  fi
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    if [ -s /tmp/lfw-suricata.pid ] && kill -0 "$(cat /tmp/lfw-suricata.pid)" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  cat /tmp/lfw-suricata-start.log >&2
  echo 'Suricata did not start' >&2
  exit 1
}
suricata_stop() {
  if [ -s /tmp/lfw-suricata.pid ]; then
    pid=$(cat /tmp/lfw-suricata.pid)
    kill -TERM "$pid" 2>/dev/null || :
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -f /tmp/lfw-suricata.pid
}
mkdir -p /tmp/lfw-ips-conf
export LFW_MODULE_CONFIG_DIR=/tmp/lfw-ips-conf
jq -n '{interface:"lfw_in",mode:"ids"}' >/tmp/lfw-ips-req.json
/workspace/modules/suricata/module.sh configure /tmp/lfw-ips-req.json >/dev/null
grep -Fq 'SURICATA_MODE="ids"' /etc/conf.d/litefw-suricata

echo 'CASE suricata/IDS-alerts-without-blocking'
suricata_start ids
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ -f /var/log/suricata/suricata.log ] && break
  sleep 1
done
test -z "$(/workspace/modules/suricata/module.sh firewall)"
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
for attempt in 1 2 3 4 5 6 7 8; do
  grep -Fq 'LiteFW simulated IPS block' /var/log/suricata/fast.log 2>/dev/null && break
  sleep 1
done
grep -Fq 'LiteFW simulated IPS block' /var/log/suricata/fast.log || {
  echo 'IDS did not alert on synthetic ICMP packet' >&2; tail -45 /var/log/suricata/suricata.log >&2; exit 1;
}
echo 'PASS actual IDS inspects packets without blocking test ping'
suricata_stop
# Force IPS assertion to prove a *new* alert, not the previous IDS event.
: >/var/log/suricata/fast.log

echo 'CASE suricata/IPS-enforces-NFQUEUE-drop'
jq -n '{interface:"lfw_in",mode:"ips"}' >/tmp/lfw-ips-req.json
/workspace/modules/suricata/module.sh configure /tmp/lfw-ips-req.json >/dev/null
suricata_start ips
rules=$(/workspace/modules/suricata/module.sh firewall)
printf '%s\n' "$rules" | grep -Fq 'LFW_FWD -j NFQUEUE --queue-num 0 --queue-bypass'
# Use the EXACT firewall rule from the module, not a test-authored stand-in.
printf '%s\n' "$rules" | while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  # shellcheck disable=SC2086
  iptables $rule
done
sleep 2
if ip netns exec lfw_ics ping -n -c 3 -W 2 198.51.100.2 >/tmp/lfw-ips-ping.log 2>&1; then
  echo 'IPS allowed a packet matching a DROP rule' >&2; cat /tmp/lfw-ips-ping.log >&2; exit 1
fi
for attempt in 1 2 3 4 5 6 7 8; do
  grep -Fq 'LiteFW simulated IPS block' /var/log/suricata/fast.log 2>/dev/null && break
  sleep 1
done
grep -Fq 'LiteFW simulated IPS block' /var/log/suricata/fast.log
echo 'PASS actual Suricata IPS enforces DROP over NFQUEUE'

echo 'CASE suricata/NFQUEUE-bypass-on-engine-stop'
suricata_stop
# --queue-bypass is deliberate, but test it: a dead IPS process must not
# silently disconnect the entire LAN while the LiteFW rule still exists.
ip netns exec lfw_ics ping -n -c 2 -W 2 198.51.100.2 >/dev/null
echo 'PASS Suricata engine stop fails open without modifying the queue rule'
