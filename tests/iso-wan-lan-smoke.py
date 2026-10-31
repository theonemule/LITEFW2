#!/usr/bin/env python3
import os, sys, subprocess, time, signal, pathlib, re
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
        ["busybox","httpd","-f","-p",f"{WAN_HOST}:8088","-h",hostdir],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    http_lan=subprocess.Popen(
        ["sudo","ip","netns","exec",NS,"busybox","httpd","-f","-p",f"{LAN_CLIENT}:8080","-h",landir],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(.5)

def vmcmd(cmd, timeout=90):
    marker=f"__LFWRC_{int(time.time()*1000000)}__"
    q.sendline(f"{cmd}; rc=$?; echo {marker}$rc")
    i=q.expect([re.escape(marker)+r"(\d+)", pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if i != 0:
        raise RuntimeError(f"VM command timed out/closed: {cmd}")
    output=q.before
    rc=int(q.match.group(1))
    # consume remainder/prompt without requiring a particular PS1
    try: q.expect(r"[#>]\s*$", timeout=5)
    except Exception: pass
    if rc:
        raise RuntimeError(f"VM command failed rc={rc}: {cmd}\nOUTPUT:\n{output}")
    return output

def boot_vm():
    global q
    accel="kvm" if os.path.exists("/dev/kvm") else "tcg"
    args=[
        "-name","litefwm-iso-wan-lan-smoke",
        "-machine",f"accel={accel}",
        "-cpu","host" if accel=="kvm" else "qemu64",
        "-smp","2","-m","768M",
        "-cdrom",ISO,"-boot","d",
        "-netdev",f"tap,id=wan,ifname={TAP_WAN},script=no,downscript=no",
        "-device","virtio-net-pci,netdev=wan,mac=52:54:00:77:00:02",
        "-netdev",f"tap,id=lan,ifname={TAP_LAN},script=no,downscript=no",
        "-device","virtio-net-pci,netdev=lan,mac=52:54:00:88:00:01",
        "-display","none","-monitor","none","-serial","stdio",
        "-no-reboot",
    ]
    log=open(SERIAL_LOG,"w", buffering=1)
    q=pexpect.spawn("qemu-system-x86_64", args, encoding="utf-8", codec_errors="ignore", timeout=240)
    q.logfile=log

    # Wait for the actual Alpine login prompt. Do not match a generic '#'
    # here: ISOLINUX's boot progress bar itself contains hash characters.
    q.expect(r"(?i)login:\s*$", timeout=300)
    q.sendline("root")
    q.expect(r"#\s*$", timeout=60)

def configure_firewall():
    # Prove the custom payload is really from the ISO.
    vmcmd("test -x /usr/sbin/lfw-setup")
    vmcmd("test -x /usr/sbin/lfwctl")
    vmcmd("grep -q 'Firewall & Network Appliance' /etc/motd")

    # The ISO must bring up Alpine's live-media modloop itself. If this fails,
    # netfilter kernel modules will be unavailable and the appliance is invalid.
    vmcmd("test -d /lib/modules/$(uname -r)")
    vmcmd("iptables --version")

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

    vmcmd("lfw-setup show | grep -q 'eth0.*wan'")
    vmcmd("lfw-setup show | grep -q 'eth1.*lan'")
    vmcmd("iptables -t nat -S LFW_SNAT | grep -q 'eth0.*MASQUERADE'")

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

    # Give the WAN host a route to the private LAN and verify an unsolicited
    # connection is still blocked by the default forward policy.
    sh(f"sudo ip route replace 10.88.0.0/24 via {WAN_FW} dev {BR_WAN}")
    rc=sh(f"ping -c1 -W2 {LAN_CLIENT} >/dev/null 2>&1", check=False)
    tests.append(("Unsolicited WAN -> LAN is blocked", rc != 0))
    print(("PASS " if rc!=0 else "FAIL ")+"Unsolicited WAN -> LAN is blocked")
    sh("sudo ip route del 10.88.0.0/24 2>/dev/null || true", check=False)

    failed=[n for n,ok in tests if not ok]
    if failed:
        raise RuntimeError("traffic failures: "+", ".join(failed))

def main():
    try:
        setup_network()
        start_servers()
        print(f"ISO: {ISO}")
        print("Topology: WAN 10.77.0.0/24 <-> eth0 | LiteFWM | eth1 <-> LAN 10.88.0.0/24")
        boot_vm()
        configure_firewall()
        traffic_tests()
        print("RESULT: ISO WAN/LAN smoke test passed")
    finally:
        cleanup()

if __name__=="__main__":
    main()
