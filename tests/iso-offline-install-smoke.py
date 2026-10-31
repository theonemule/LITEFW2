#!/usr/bin/env python3
import os, pathlib, re, subprocess, sys, time, fcntl
import pexpect

if len(sys.argv) != 2:
    raise SystemExit("usage: iso-offline-install-smoke.py /path/to/litefwm.iso")

ISO=os.path.abspath(sys.argv[1])
if not os.path.isfile(ISO):
    raise SystemExit(f"ISO not found: {ISO}")

WORK=os.environ.get("LITEFWM_OFFLINE_WORK", "/dev/shm/litefwm-offline-install")
DISK=f"{WORK}/disk.qcow2"
LIVE_LOG=f"{WORK}/live-serial.log"
DISK_LOG=f"{WORK}/disk-serial.log"
pathlib.Path(WORK).mkdir(parents=True, exist_ok=True)
q=None
# BusyBox shells may emit an ANSI cursor-position report request (CSI 6 n)
# after displaying the root prompt. Accept that escape without accepting
# a Password: challenge or any other arbitrary console text.
ROOT_PROMPT=r"#(?:\x1b\[[0-9;]*[A-Za-z])*\s*$"

def sh(args, check=True):
    p=subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and p.returncode:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{p.stdout}")
    return p.stdout

def usable_kvm():
    """A visible /dev/kvm is not necessarily usable in hosted CI."""
    try:
        fd = os.open("/dev/kvm", os.O_RDWR | os.O_CLOEXEC)
        try:
            return fcntl.ioctl(fd, 0xAE00, 0) == 12  # KVM_GET_API_VERSION
        finally:
            os.close(fd)
    except OSError:
        return False


def spawn_vm(from_iso):
    global q
    accel = os.environ.get("LITEFWM_QEMU_ACCEL") or ("kvm" if usable_kvm() else "tcg")
    if accel not in ("kvm", "tcg"):
        raise ValueError("LITEFWM_QEMU_ACCEL must be kvm or tcg")
    print(f"QEMU acceleration: {accel}", flush=True)
    args=[
        "-name","litefwm-offline-install-smoke",
        "-machine",f"accel={accel}",
        "-cpu","host" if accel=="kvm" else "qemu64",
        "-smp","2","-m","1024M",
        "-drive",f"file={DISK},if=virtio,format=qcow2",
        "-nic","none",
        "-display","none","-monitor","none","-serial","stdio",
        "-no-reboot",
    ]
    if from_iso:
        args += ["-cdrom",ISO,"-boot","order=d"]
        logpath=LIVE_LOG
    else:
        args += ["-boot","order=c"]
        logpath=DISK_LOG
    log=open(logpath,"w", buffering=1)
    q=pexpect.spawn("qemu-system-x86_64", args, encoding="utf-8", codec_errors="ignore", timeout=300)
    q.logfile=log
    q.expect(r"(?i)login:\s*$", timeout=360)
    q.sendline("root")
    i=q.expect([ROOT_PROMPT, r"(?i)password:\s*$"], timeout=60)
    if i == 1:
        raise RuntimeError("ISO or installed system requested a root password; local console login must be passwordless")

def vmcmd(cmd, timeout=120):
    marker=f"__OFFRC_{int(time.time()*1000000)}__"
    q.sendline(f"{cmd}; rc=$?; echo {marker}$rc")
    i=q.expect([re.escape(marker)+r"(\d+)", pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if i != 0:
        raise RuntimeError(f"VM command timed out/closed: {cmd}")
    out=q.before
    rc=int(q.match.group(1))
    try: q.expect(ROOT_PROMPT, timeout=5)
    except Exception: pass
    if rc:
        raise RuntimeError(f"VM command failed rc={rc}: {cmd}\n{out}")
    return out

def stop_vm():
    global q
    if q is not None and q.isalive():
        q.terminate(force=True)
    q=None

def install_from_iso():
    spawn_vm(True)
    vmcmd("test ! -e /sys/class/net/eth0")
    vmcmd("grep -q '/media/cdrom/apks' /etc/apk/repositories")
    # Prove the media repository can resolve the full base install and supported
    # optional modules with APK network access explicitly disabled.
    pkgs=(
        "alpine-base alpine-conf linux-lts syslinux e2fsprogs "
        "ifupdown-ng iproute2 iptables dnsmasq jq util-linux openssh "
        "lighttpd lighttpd-mod_auth apache2-utils sudo busybox-openrc "
        "bind bind-tools bind-openrc openvpn openvpn-openrc easy-rsa inadyn inadyn-openrc"
    )
    vmcmd(f"apk add --simulate --no-network {pkgs} >/tmp/apk-sim.txt", timeout=180)
    vmcmd("grep -q 'LiteFWM appliance installer' /etc/motd")
    vmcmd("test -x /usr/sbin/lfwctl")
    vmcmd("test ! -e /root/litefwm-admin.txt")
    vmcmd("test -x /usr/local/sbin/setup-alpine")
    vmcmd("test -x /usr/sbin/setup-alpine")
    vmcmd("test -x /usr/local/sbin/litefw2-console-login")
    vmcmd("grep -qx 'tty1::respawn:-/bin/sh' /etc/inittab")
    vmcmd("! grep -q '^tty0::respawn:' /etc/inittab")
    vmcmd("! ps -eo args | grep -q '[g]etty .*tty0'")
    # Confirm a real root shell is rendered on VGA tty1, not a login/password
    # challenge. /dev/vcs1 exposes the guest virtual console text buffer.
    vmcmd("test -c /dev/vcs1")
    vmcmd("i=0; until dd if=/dev/vcs1 bs=4096 count=1 2>/dev/null | tr -d '\\000' | grep -q 'localhost:~#'; do i=$((i+1)); [ $i -lt 30 ] || exit 1; sleep 1; done", timeout=70)
    vmcmd("awk -F: '$1==\"root\" {exit ($2!=\"\")} END {}' /etc/shadow")
    # This low-level setup-disk smoke bypasses the integrated setup-alpine
    # prompts; create a test-only hash so it tests disk persistence honestly.
    vmcmd("htpasswd -bB -C 12 -c /etc/litefwm/htpasswd admin 'SmokeTestOnlyPassword123!' >/dev/null")
    vmcmd("chown root:lighttpd /etc/litefwm/htpasswd && chmod 0640 /etc/litefwm/htpasswd")
    vmcmd("test -s /etc/litefwm/htpasswd")
    # setup-disk itself has no network override, so the absence of any NIC plus
    # a media-only repositories file makes this a hard offline installation test.
    vmcmd("cp /etc/apk/repositories /tmp/repositories.before")
    vmcmd("grep '/media/cdrom/apks' /tmp/repositories.before")
    q.sendline("setup-disk -m sys -s 0 /dev/vda")
    i=q.expect([r"(?is)erase.*continue.*\(y/n\)", r"(?is)installation is complete", ROOT_PROMPT, pexpect.EOF, pexpect.TIMEOUT], timeout=180)
    if i == 0:
        q.sendline("y")
        i=q.expect([r"(?is)installation is complete", ROOT_PROMPT, pexpect.EOF, pexpect.TIMEOUT], timeout=600)
    if i not in (0,1):
        raise RuntimeError("offline setup-disk did not complete")
    if i == 0:
        try: q.expect(ROOT_PROMPT, timeout=60)
        except Exception: pass
    vmcmd("test -b /dev/vda")
    stop_vm()

def verify_installed_system():
    spawn_vm(False)
    for p in (
        "alpine-base alpine-conf linux-lts ifupdown-ng iproute2 iptables dnsmasq jq "
        "util-linux openssh lighttpd lighttpd-mod_auth apache2-utils sudo busybox-openrc"
    ).split():
        vmcmd(f"apk info -e {p}")
    vmcmd("test -x /usr/sbin/lfwctl")
    vmcmd("test -x /usr/sbin/lfw-setup")
    vmcmd("test -x /usr/local/sbin/litefw2-console-login")
    vmcmd("grep -qx 'tty1::respawn:-/bin/sh' /etc/inittab")
    vmcmd("! grep -q '^tty0::respawn:' /etc/inittab")
    vmcmd("! ps -eo args | grep -q '[g]etty .*tty0'")
    # Confirm a real root shell is rendered on VGA tty1, not a login/password
    # challenge. /dev/vcs1 exposes the guest virtual console text buffer.
    vmcmd("test -c /dev/vcs1")
    vmcmd("i=0; until dd if=/dev/vcs1 bs=4096 count=1 2>/dev/null | tr -d '\\000' | grep -q 'localhost:~#'; do i=$((i+1)); [ $i -lt 30 ] || exit 1; sleep 1; done", timeout=70)
    vmcmd("test -x /usr/lib/litefwm/cgi/api.cgi")
    vmcmd("test -f /usr/share/litefwm/www/index.html")
    vmcmd("test -f /etc/lighttpd/litefwm.conf")
    vmcmd("test -f /etc/sysctl.d/90-litefwm.conf")
    vmcmd("test -f /etc/iptables/rules-save")
    vmcmd("test -L /etc/runlevels/default/lighttpd")
    vmcmd("test -L /etc/runlevels/default/dnsmasq")
    vmcmd("test -L /etc/runlevels/boot/iptables")
    vmcmd("test -L /etc/runlevels/boot/litefwm-init")
    vmcmd("test -s /etc/litefwm/htpasswd")
    vmcmd("test ! -e /root/litefwm-admin.txt")
    vmcmd("grep -q '^admin:' /etc/litefwm/htpasswd")
    vmcmd("grep -q '^PermitRootLogin prohibit-password$' /etc/ssh/sshd_config.d/90-litefwm-console-only.conf")
    vmcmd("grep -q '^PermitEmptyPasswords no$' /etc/ssh/sshd_config.d/90-litefwm-console-only.conf")
    vmcmd("awk -F: '$1==\"root\" {exit ($2!=\"\")} END {}' /etc/shadow")
    stop_vm()

def main():
    global q
    try:
        try: os.unlink(DISK)
        except FileNotFoundError: pass
        sh(["qemu-img","create","-f","qcow2",DISK,os.environ.get("LITEFWM_DISK_SIZE","3G")])
        print(f"ISO: {ISO}")
        print("Network: none (QEMU -nic none)")
        install_from_iso()
        print("PASS setup-disk completed with no NIC/network")
        verify_installed_system()
        print("PASS installed Alpine base and LiteFWM runtime packages are present")
        print("PASS LiteFWM CLI, API, web UI, config and boot services survived disk install")
        print("RESULT: offline ISO install smoke test passed")
    finally:
        stop_vm()

if __name__=="__main__":
    main()
