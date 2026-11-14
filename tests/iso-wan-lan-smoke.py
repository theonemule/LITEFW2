#!/usr/bin/env python3
import os, sys, subprocess, time, signal, pathlib, re, json, shlex
import pexpect

if len(sys.argv) != 2:
    print("usage: iso-wan-lan-smoke.py /path/to/litefwm.iso", file=sys.stderr)
    sys.exit(2)

ISO = os.path.abspath(sys.argv[1])
if not os.path.isfile(ISO):
    raise SystemExit(f"ISO not found: {ISO}")

BR_WAN="lfwisowan"
BR_LAN="lfwisolan"
TAP_WAN="lfwisofw0"
TAP_LAN="lfwisofw1"
NS="lfwisocli"
VETH_H="lfwisoclih"
VETH_N="lfwisoclin"
WAN_HOST="10.77.0.1"
WAN_FW="10.77.0.2"
LAN_FW="10.88.0.1"
LAN_CLIENT="10.88.0.10"
WORK="/dev/shm/litefwm-iso-smoke"
SERIAL_LOG=f"{WORK}/serial.log"
ROOT_PROMPT=r"#(?:[ \t]|\x1b\[[0-9;]*[A-Za-z])*$"

pathlib.Path(WORK).mkdir(parents=True, exist_ok=True)
http_host=None
http_lan=None
q=None

def sh(cmd, check=True, capture=False):
    p=subprocess.run(cmd, shell=True, text=True,
                     stdout=subprocess.PIPE if capture else None,
                     stderr=subprocess.STDOUT if capture else None)
    if check and p.returncode:
        raise RuntimeError(f"command failed ({p.returncode}): {cmd}\n{p.stdout or ''}")
    return (p.stdout or "").strip() if capture else p.returncode

def cleanup():
    global http_host, http_lan, q
    try:
        if q is not None and q.isalive():
            q.terminate(force=True)
    except Exception:
        pass
    for p in (http_host, http_lan):
        try:
            if p and p.poll() is None:
                p.terminate()
                p.wait(timeout=2)
        except Exception:
            try: p.kill()
            except Exception: pass
    sh(f"sudo ip netns pids {NS} 2>/dev/null | xargs -r sudo kill 2>/dev/null || true", check=False)
    sh(f"sudo ip netns del {NS} 2>/dev/null || true", check=False)
    for i in (TAP_WAN,TAP_LAN,VETH_H,BR_WAN,BR_LAN):
        sh(f"sudo ip link del {i} 2>/dev/null || true", check=False)

def setup_network():
    cleanup()
    pathlib.Path(WORK).mkdir(parents=True, exist_ok=True)
    sh(f"sudo ip link add {BR_WAN} type bridge")
    sh(f"sudo ip addr add {WAN_HOST}/24 dev {BR_WAN}")
    sh(f"sudo ip link set {BR_WAN} up")
    sh(f"sudo ip link add {BR_LAN} type bridge")
    sh(f"sudo ip link set {BR_LAN} up")

    uid=os.getuid()
    sh(f"sudo ip tuntap add dev {TAP_WAN} mode tap user {uid}")
    sh(f"sudo ip link set {TAP_WAN} master {BR_WAN}")
    sh(f"sudo ip link set {TAP_WAN} up")
    sh(f"sudo ip tuntap add dev {TAP_LAN} mode tap user {uid}")
    sh(f"sudo ip link set {TAP_LAN} master {BR_LAN}")
    sh(f"sudo ip link set {TAP_LAN} up")

    sh(f"sudo ip netns add {NS}")
    sh(f"sudo ip link add {VETH_H} type veth peer name {VETH_N}")
    sh(f"sudo ip link set {VETH_H} master {BR_LAN}")
    sh(f"sudo ip link set {VETH_H} up")
    sh(f"sudo ip link set {VETH_N} netns {NS}")
    sh(f"sudo ip netns exec {NS} ip link set lo up")
    sh(f"sudo ip netns exec {NS} ip link set {VETH_N} name eth0")
    sh(f"sudo ip netns exec {NS} ip addr add {LAN_CLIENT}/24 dev eth0")
    sh(f"sudo ip netns exec {NS} ip link set eth0 up")
    sh(f"sudo ip netns exec {NS} ip route add default via {LAN_FW}")

def start_servers():
    global http_host, http_lan
    hostdir=f"{WORK}/wan-www"
    landir=f"{WORK}/lan-www"
    pathlib.Path(hostdir).mkdir(exist_ok=True)
    pathlib.Path(landir).mkdir(exist_ok=True)
    pathlib.Path(f"{hostdir}/index.html").write_text("WAN-SERVICE\n")
    pathlib.Path(f"{landir}/index.html").write_text("LAN-SERVICE\n")
    http_host=subprocess.Popen(
        ["httpd","-f","-p",f"{WAN_HOST}:8088","-h",hostdir],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    http_lan=subprocess.Popen(
        ["sudo","ip","netns","exec",NS,"httpd","-f","-p",f"{LAN_CLIENT}:8080","-h",landir],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(.5)
    for label,proc in (("WAN HTTP fixture",http_host),("LAN HTTP fixture",http_lan)):
        if proc.poll() is not None:
            raise RuntimeError(f"{label} exited immediately with rc={proc.returncode}")
    # Fail fast if the fixture is unreachable *before* launching QEMU.
    sh(f"curl --noproxy '*' -fsS --connect-timeout 2 http://{WAN_HOST}:8088/ | grep -q WAN-SERVICE")
    sh(f"sudo ip netns exec {NS} curl --noproxy '*' -fsS --connect-timeout 2 http://{LAN_CLIENT}:8080/ | grep -q LAN-SERVICE")
    print("PASS WAN and LAN HTTP fixture servers are reachable before guest boot",flush=True)

def vmcmd(cmd, timeout=90):
    marker=f"__LFWRC_{int(time.time()*1000000)}__"
    q.sendline(f"{cmd}; rc=$?; echo {marker}$rc")
    i=q.expect([re.escape(marker)+r"(\d+)", pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if i != 0:
        raise RuntimeError(f"VM command timed out/closed: {cmd}")
    output=q.before
    rc=int(q.match.group(1))
    # consume remainder/prompt without requiring a particular PS1
    try: q.expect(ROOT_PROMPT, timeout=3)
    except Exception: pass
    if rc:
        raise RuntimeError(f"VM command failed rc={rc}: {cmd}\nOUTPUT:\n{output}")
    return output

def boot_vm():
    global q
    # Hosted or privileged Docker may expose a /dev/kvm node that is not
    # usable. The QA runner explicitly requests TCG, which works everywhere.
    accel=os.environ.get("LITEFWM_QEMU_ACCEL") or ("kvm" if os.path.exists("/dev/kvm") else "tcg")
    args=[
        "-name","litefwm-iso-wan-lan-smoke",
        "-machine",f"accel={accel}",
        "-cpu","host" if accel=="kvm" else "qemu64",
        "-smp","2","-m","768M",
        "-netdev",f"tap,id=wan,ifname={TAP_WAN},script=no,downscript=no",
        "-device","virtio-net-pci,netdev=wan,mac=52:54:00:77:00:02",
        "-netdev",f"tap,id=lan,ifname={TAP_LAN},script=no,downscript=no",
        "-device","virtio-net-pci,netdev=lan,mac=52:54:00:88:00:01",
        "-display","none","-monitor","none","-serial","stdio",
        "-no-reboot",
    ]
    installed_disk=os.environ.get("LITEFWM_WANLAN_DISK","")
    if installed_disk:
        if not os.path.isfile(installed_disk):
            raise RuntimeError("Installed QEMU disk does not exist: "+installed_disk)
        args += ["-drive",f"file={installed_disk},if=virtio,format=qcow2", "-boot","order=c"]
    else:
        args += ["-cdrom",ISO,"-boot","order=d"]
    log=open(SERIAL_LOG,"w", buffering=1)
    q=pexpect.spawn("qemu-system-x86_64", args, encoding="utf-8", codec_errors="ignore", timeout=240)
    q.logfile=log

    # Wait for the actual Alpine login prompt. Do not match a generic '#'
    # here: ISOLINUX's boot progress bar itself contains hash characters.
    q.expect(r"(?i)login:\s*$", timeout=300)
    q.sendline("root")
    q.expect(ROOT_PROMPT, timeout=60)

def configure_firewall():
    # Prove the custom payload is really from the ISO.
    vmcmd("test -x /usr/sbin/lfw-setup")
    vmcmd("test -x /usr/sbin/lfwctl")
    vmcmd("grep -q 'Firewall & Network Appliance' /etc/motd")

    # The ISO must bring up Alpine's live-media modloop itself. If this fails,
    # netfilter kernel modules will be unavailable and the appliance is invalid.
    vmcmd("test -d /lib/modules/$(uname -r)")
    vmcmd("nft --version")

    # Static WAN first. lfw-setup then adopts that live configuration as WAN.
    vmcmd("ip link set eth0 up")
    vmcmd("ip -4 addr flush dev eth0")
    vmcmd(f"ip addr add {WAN_FW}/24 dev eth0")
    vmcmd(f"ip route replace default via {WAN_HOST} dev eth0")
    vmcmd("lfwctl get segments >/tmp/segments.json", timeout=120)
    vmcmd("lfw-setup wan eth0", timeout=120)
    vmcmd(f"lfw-setup lan eth1 {LAN_FW}/24", timeout=120)

    # A firewall appliance must forward packets. The installed application
    # normally persists this via sysctl; set it explicitly for the live-media test.
    vmcmd("sysctl -w net.ipv4.ip_forward=1 >/dev/null")
    vmcmd("""lfwctl op rule.add '{"chain":"forward","action":"accept","in":"eth1","out":"eth0","description":"ISO LAN to WAN"}' >/dev/null""")
    vmcmd(f"""lfwctl op forward.add '{{"in":"eth0","proto":"tcp","port":"9090","to":"{LAN_CLIENT}","toPort":"8080","description":"ISO WAN to LAN"}}' >/dev/null""")

    # The live installation media intentionally has no web administrator
    # until setup-alpine prompts for one. Provision a fixture credential in
    # this disposable VM before testing its authenticated management UI.
    vmcmd("htpasswd -bBc /etc/litefwm/htpasswd isoqa 'OnlyForIsolatedSmoke123!' >/dev/null")
    vmcmd("chown root:lighttpd /etc/litefwm/htpasswd; chmod 0640 /etc/litefwm/htpasswd")
    # Regression for the apkovl root-dir mode: a 0700 root prevents all
    # unprivileged services from reading configs or executing programs.
    vmcmd("test \"$(stat -c %a /)\" = 755")
    vmcmd("su -s /bin/sh lighttpd -c 'test -x /bin/sh && test -w /var/log/lighttpd/error.log'")
    vmcmd("test -f /var/log/lighttpd/error.log")
    # Live-media and installed disks can have different on-disk user/group
    # ownership; enforce actual write access and no unrelated-user writes.
    vmcmd("su -s /bin/sh nobody -c 'test ! -w /var/log/lighttpd/error.log'")
    vmcmd("lighttpd -tt -f /etc/lighttpd/lighttpd.conf")
    try:
        vmcmd("rc-service lighttpd restart", timeout=100)
    except RuntimeError:
        for command in [
            "echo ---WEBSERVER-CONFIG---; cat /etc/lighttpd/litefwm-bind.conf",
            "echo ---BASIC-CONFIG---; cat /etc/lighttpd/lighttpd.conf",
            "echo ---PORTS---; ss -ltn",
            "echo ---LIGHTTPD-CONFIG-TEST---; lighttpd -tt -f /etc/lighttpd/lighttpd.conf 2>&1",
            "echo ---LIGHTTPD-LOG---; tail -80 /var/log/lighttpd/error.log 2>&1",
            "echo ---LOG-PATH-PERMISSIONS---; ls -ld /var /var/log /var/log/lighttpd /var/log/lighttpd/error.log; stat -c '%U:%G %a %n' /var /var/log /var/log/lighttpd /var/log/lighttpd/error.log",
            "echo ---TEST-WRITE-AS-LIGHTTPD---; su -s /bin/sh lighttpd -c 'echo test >> /var/log/lighttpd/error.log'; echo unprivileged_rc=$?",
            "echo ---AUTH-FILE-PERMISSIONS---; ls -ld /etc/litefwm /etc/litefwm/htpasswd /var/log/lighttpd /run",
            "echo ---LIGHTTPD-RUNTIME---; timeout 6 lighttpd -D -f /etc/lighttpd/lighttpd.conf 2>&1",
            "echo ---SERVICE-STATUS---; rc-service lighttpd status 2>&1",
        ]:
            try:
                print(vmcmd(command + "; true", timeout=50), flush=True)
            except Exception as err:
                print("DIAG error", err, flush=True)
        print("--- TEST TEMPORARY PARENT-PATH SEARCH PERMISSION ---",flush=True)
        try:
            print(vmcmd("chmod a+x /var/log; rc-service lighttpd start; rc-service lighttpd status; true",timeout=50),flush=True)
        except Exception as err:
            print("TEMP permission probe failed",err,flush=True)
        # A temporary test-only workaround cannot count as ISO validation.
        raise
    vmcmd(f"ss -ltn | grep -Fq '{LAN_FW}:80'")
    vmcmd(f"! ss -ltn | grep -Fq '{WAN_FW}:80'")
    vmcmd("! ss -ltn | grep -q '0.0.0.0:80'")
    vmcmd("nft list chain inet litefw INPUT | grep -q 'LFW_WEB'")
    vmcmd("nft list chain inet litefw LFW_WEB | grep -q 'eth1.*accept'")
    vmcmd("nft list chain inet litefw LFW_WEB | grep -q 'drop'")
    vmcmd("lfw-setup show | grep -q 'eth0.*wan'")
    vmcmd("lfw-setup show | grep -q 'eth1.*lan'")
    vmcmd("nft list chain inet litefw LFW_SNAT | grep -q 'eth0.*masquerade'")

    # Exercise the structured policy API from the booted ISO, including host
    # input/output hooks, before any disk installation or release deployment.
    vmcmd("""lfwctl op rule.add '{"source":{"scope":"wan"},"destination":{"scope":"host"},"proto":"icmp","action":"drop","description":"WAN ping denied"}' >/tmp/host-rule.json""")
    vmcmd("jq -e '.ok and (.result.id|length==8)' /tmp/host-rule.json >/dev/null")
    vmcmd("""lfwctl get firewall | jq -e '.firewall.rules[]|select(.description=="WAN ping denied" and .destination.scope=="host" and .chain=="input")' >/dev/null""")
    vmcmd("""lfwctl op rule.add '{"source":{"scope":"host"},"destination":{"scope":"wan","ports":"53"},"proto":"udp","action":"drop","description":"Local DNS denied"}' >/tmp/output-rule.json""")
    vmcmd("""lfwctl get firewall | jq -e '.firewall.rules[]|select(.description=="Local DNS denied" and .source.scope=="host" and .chain=="output")' >/dev/null""")
    vmcmd("""id=$(jq -r .result.id /tmp/host-rule.json); lfwctl op rule.delete "$(printf '{\"id\":\"%s\"}' "$id")" >/dev/null""")
    vmcmd("""id=$(jq -r .result.id /tmp/output-rule.json); lfwctl op rule.delete "$(printf '{\"id\":\"%s\"}' "$id")" >/dev/null""")

def traffic_tests():
    tests=[]
    def check(name, cmd):
        rc=sh(cmd, check=False)
        tests.append((name, rc==0))
        print(("PASS " if rc==0 else "FAIL ")+name)

    check("LAN client reaches firewall LAN", f"sudo ip netns exec {NS} ping -c2 -W2 {LAN_FW} >/dev/null")
    check("LAN -> WAN HTTP passes through firewall/NAT",
          f"sudo ip netns exec {NS} busybox wget -q -T 5 -O - http://{WAN_HOST}:8088/ | grep -q WAN-SERVICE")
    check("WAN -> LAN port forward reaches LAN client",
          f"busybox wget -q -T 5 -O - http://{WAN_FW}:9090/ | grep -q LAN-SERVICE")

    # Put a source/destination rule above the existing allow and test its
    # real effect on traffic rather than only its JSON or chain position.
    vmcmd("""lfwctl op rule.add '{"source":{"scope":"interface","interface":"eth1"},"destination":{"scope":"wan","ports":"8088"},"proto":"tcp","action":"drop","position":"0","description":"Block WAN HTTP"}' >/tmp/block-rule.json""")
    vmcmd("""lfwctl get firewall | jq -e '.firewall.rules[0].description=="Block WAN HTTP"' >/dev/null""")
    denied=sh(f"sudo ip netns exec {NS} busybox wget -q -T 3 -O - http://{WAN_HOST}:8088/ >/dev/null 2>&1", check=False)
    tests.append(("Higher-priority block rule denies allowed LAN WAN connection", denied!=0))
    print(("PASS " if denied!=0 else "FAIL ")+"Higher-priority block rule denies allowed LAN WAN connection")
    vmcmd("""lfwctl op rule.delete "$(jq -nc --arg id "$(jq -r .result.id /tmp/block-rule.json)" '{id:$id}')" >/dev/null""")
    check("Deleted block restores allowed WAN traffic",
          f"sudo ip netns exec {NS} busybox wget -q -T 5 -O - http://{WAN_HOST}:8088/ | grep -q WAN-SERVICE")

    # Give the WAN host a route to the private LAN and verify an unsolicited
    # connection is still blocked by the default forward policy.
    sh(f"sudo ip route replace 10.88.0.0/24 via {WAN_FW} dev {BR_WAN}")
    rc=sh(f"ping -c1 -W2 {LAN_CLIENT} >/dev/null 2>&1", check=False)
    tests.append(("Unsolicited WAN -> LAN is blocked", rc != 0))
    print(("PASS " if rc!=0 else "FAIL ")+"Unsolicited WAN -> LAN is blocked")
    sh("sudo ip route del 10.88.0.0/24 2>/dev/null || true", check=False)

    # Exercise the *real* Lighttpd Basic-authenticated HTTP UI and API on the
    # booted ISO, from a client on the separate LAN. WAN access must be denied.
    base=f"http://{LAN_FW}"
    auth="isoqa:OnlyForIsolatedSmoke123!"
    noauth=sh(f"sudo ip netns exec {NS} curl --noproxy '*' -sS -o /dev/null -w '%{{http_code}}' {base}/api/firewall", capture=True)
    tests.append(("HTTP API refuses unauthenticated LAN requests", noauth=="401"))
    check("Authenticated UI served on LAN", f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' {base}/ | grep -q LiteFWM")
    check("Shipped UI uses unified source-to-destination rule list",
          f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' {base}/app.js | grep -Fq 'Traffic rules — one ordered policy'")
    check("Shipped OpenAPI describes structured firewall endpoints",
          f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' {base}/docs/openapi.json | jq -e '.components.schemas | has(\"FirewallEndpoint\") and has(\"FirewallRuleWrite\")' >/dev/null")
    api=sh(f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' {base}/api/firewall", capture=True)
    try:
        state=json.loads(api)
        valid=bool(state.get("firewall",{}).get("rules"))
    except (ValueError,TypeError): valid=False
    tests.append(("Authenticated firewall API returns live rule list",valid))
    print(("PASS " if valid else "FAIL ")+"Authenticated firewall API returns live rule list")
    wanweb=sh(f"curl --noproxy '*' --connect-timeout 2 -fsS http://{WAN_FW}/ >/dev/null 2>&1",check=False)
    tests.append(("Firewall web UI unreachable through WAN", wanweb!=0))
    print(("PASS " if wanweb!=0 else "FAIL ")+"Firewall web UI unreachable through WAN")
    body={"source":{"scope":"wan"},"destination":{"scope":"host"},
          "action":"drop","proto":"icmp","description":"HTTP API WAN ping block"}
    endpoint=f"{base}/api/firewall/rules/add"
    cmd=(f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' "
         f"-H 'Content-Type: application/json' -H 'X-LiteFWM: 1' "
         f"--data {shlex.quote(json.dumps(body))} {endpoint}")
    try:
        new_rule=json.loads(sh(cmd,capture=True))
        rule_id=new_rule["result"]["id"]
        vmcmd("""lfwctl get firewall | jq -e '.firewall.rules[]|select(.description=="HTTP API WAN ping block" and .destination.scope=="host")' >/dev/null""")
        changed=dict(body, id=rule_id, action="reject", description="HTTP API edited WAN ping")
        update=json.loads(sh(
           f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' "
           f"-H 'Content-Type: application/json' -H 'X-LiteFWM: 1' "
           f"--data {shlex.quote(json.dumps(changed))} {base}/api/firewall/rules/update",capture=True))
        if not update.get("ok"):
            raise RuntimeError("HTTP rule edit API refused valid change")
        vmcmd("""lfwctl get firewall | jq -e '.firewall.rules[]|select(.description=="HTTP API edited WAN ping" and .action=="reject" and .managed==true)' >/dev/null""")
        deleted=json.loads(sh(
           f"sudo ip netns exec {NS} curl --noproxy '*' -fsS -u '{auth}' "
           f"-H 'Content-Type: application/json' -H 'X-LiteFWM: 1' "
           f"--data {shlex.quote(json.dumps({'id':rule_id}))} {base}/api/firewall/rules/delete",capture=True))
        api_mutation=bool(deleted.get("ok"))
    except Exception as err:
        print("HTTP firewall mutation failed:",err)
        api_mutation=False
    tests.append(("HTTP API creates, edits and deletes a real host firewall rule",api_mutation))
    print(("PASS " if api_mutation else "FAIL ")+"HTTP API creates, edits and deletes a real host firewall rule")

    failed=[n for n,ok in tests if not ok]
    if failed:
        raise RuntimeError("traffic failures: "+", ".join(failed))

def main():
    try:
        setup_network()
        start_servers()
        print(f"ISO: {ISO}")
        if os.environ.get("LITEFWM_WANLAN_DISK"):
            print("Booted from installed disk: "+os.environ["LITEFWM_WANLAN_DISK"])
        print("Topology: WAN 10.77.0.0/24 <-> eth0 | LiteFWM | eth1 <-> LAN 10.88.0.0/24")
        boot_vm()
        configure_firewall()
        traffic_tests()
        print("RESULT: ISO WAN/LAN smoke test passed")
    finally:
        cleanup()

if __name__=="__main__":
    main()