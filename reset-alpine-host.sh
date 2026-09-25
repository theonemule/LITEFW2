#!/bin/sh
# Reset a dedicated Alpine LiteVMM/LiteFWM test host to a near-fresh state.
# Keeps the Alpine base system, OpenSSH, the admin account, and one DHCP uplink.
# Git is kept by default.
# If invoked through sudo, sudo is also kept to avoid locking out the admin user.
set -eu
umask 022

KEEP_GIT=1
KEEP_SUDO=auto
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: reset-alpine-host.sh [--yes] [--no-git] [--keep-sudo|--purge-sudo]

Destructively resets a dedicated Alpine LiteVMM/LiteFWM development host:
  - stops LiteVMM, LiteFWM, VM, Docker, Lighttpd, NFS and tunnel processes
  - flushes appliance firewall/NAT rules back to permissive defaults
  - removes every non-loopback, non-physical network link
  - restores the primary physical NIC to DHCP and rewrites Alpine networking
  - removes LiteVMM/LiteFWM services, binaries, configuration and state
  - removes Docker/container state, certificates, VM state and generated data
  - purges packages installed by LiteVMM/LiteFWM
  - leaves Alpine base + OpenSSH + CA certificates; Git is kept by default
  - keeps sudo automatically when invoked through sudo

The primary physical NIC is selected from the current default-route device when
possible, otherwise the first hardware-backed Ethernet device. The reset writes
/etc/network/interfaces with loopback plus DHCP on that NIC.

This script is intended for disposable/dedicated Alpine development hosts.
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-git) KEEP_GIT=0 ;;
        --keep-sudo) KEEP_SUDO=1 ;;
        --purge-sudo) KEEP_SUDO=0 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "Run as root, for example: sudo ./reset-alpine-host.sh --yes"
[ -r /etc/os-release ] || die "/etc/os-release is missing"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "alpine" ] || die "This reset script only supports Alpine Linux"

if [ "$KEEP_SUDO" = auto ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-root}" != root ]; then
        KEEP_SUDO=1
    else
        KEEP_SUDO=0
    fi
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    cat >&2 <<'EOF'
This is DESTRUCTIVE.

It deletes all LiteVMM/LiteFWM state, VMs, disks, backups, replicas, peer
state, Docker containers/images/volumes, certificates, generated web/network
configuration and installed appliance tooling. It also removes non-physical
network devices and restores the primary physical NIC to DHCP.

The source checkout containing this script is NOT deleted.
EOF
    printf '\nType PURGE-LITEVMM to continue: ' >&2
    read -r answer
    [ "$answer" = "PURGE-LITEVMM" ] || die "Cancelled"
fi

service_stop_disable() {
    svc=$1
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" stop >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del "$svc" default >/dev/null 2>&1 || true
        rc-update del "$svc" boot >/dev/null 2>&1 || true
    fi
}


is_physical_link() {
    name=$1
    [ "$name" != lo ] && [ -e "/sys/class/net/$name/device" ]
}

select_current_ipv4() {
    default_dev=''
    if command -v ip >/dev/null 2>&1; then
        default_dev=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
        if [ -n "$default_dev" ]; then
            ip -4 addr show dev "$default_dev" scope global 2>/dev/null |
                awk '/inet / { split($2,a,"/"); print a[1]; exit }'
            return 0
        fi
    fi
    return 1
}

select_primary_nic() {
    default_dev=''
    if command -v ip >/dev/null 2>&1; then
        default_dev=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
    fi

    if [ -n "$default_dev" ] && is_physical_link "$default_dev"; then
        printf '%s
' "$default_dev"
        return 0
    fi

    # If the default route lives on a bridge, prefer a physical member.
    if [ -n "$default_dev" ] && command -v ip >/dev/null 2>&1; then
        for name in $(ip -o link show master "$default_dev" 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1); do
            if is_physical_link "$name"; then
                printf '%s
' "$name"
                return 0
            fi
        done
    fi

    for path in /sys/class/net/*; do
        [ -e "$path" ] || continue
        name=$(basename "$path")
        if is_physical_link "$name"; then
            printf '%s
' "$name"
            return 0
        fi
    done

    return 1
}

flush_firewall_state() {
    if command -v iptables >/dev/null 2>&1; then
        iptables -P INPUT ACCEPT >/dev/null 2>&1 || true
        iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
        iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
        for table in filter nat mangle raw security; do
            iptables -t "$table" -F >/dev/null 2>&1 || true
            iptables -t "$table" -X >/dev/null 2>&1 || true
        done
    fi
    if command -v nft >/dev/null 2>&1; then
        nft flush ruleset >/dev/null 2>&1 || true
    fi
}

delete_nonphysical_links() {
    command -v ip >/dev/null 2>&1 || return 0

    # Detach physical NICs from any old bridges first. Never delete hardware
    # backed interfaces or loopback.
    for path in /sys/class/net/*; do
        [ -e "$path" ] || continue
        name=$(basename "$path")
        is_physical_link "$name" || continue
        ip link set dev "$name" nomaster >/dev/null 2>&1 || true
        ip link set dev "$name" up >/dev/null 2>&1 || true
    done

    # Delete deepest/ephemeral links first, then bridges. Repeating the pass
    # handles dependencies such as VLAN-on-bridge and veth-on-bridge.
    pass=0
    while [ "$pass" -lt 3 ]; do
        for path in /sys/class/net/*; do
            [ -e "$path" ] || continue
            name=$(basename "$path")
            [ "$name" = lo ] && continue
            is_physical_link "$name" && continue
            ip link delete dev "$name" >/dev/null 2>&1 || true
        done
        pass=$((pass + 1))
    done
}

restore_alpine_dhcp() {
    nic=$1
    requested_ip=${2:-}
    [ -n "$nic" ] || die "Could not identify a physical NIC to restore to DHCP"

    if [ -n "$requested_ip" ]; then
        log "Restoring Alpine networking on $nic using DHCP (requesting $requested_ip)"
    else
        log "Restoring Alpine networking on $nic using DHCP"
    fi

    mkdir -p /etc/network/interfaces.d
    rm -f /etc/network/interfaces.d/* 2>/dev/null || true
    {
        printf 'auto lo
'
        printf 'iface lo inet loopback

'
        printf 'auto %s
' "$nic"
        printf 'iface %s inet dhcp
' "$nic"
        [ -z "$requested_ip" ] || printf '    udhcpc_opts -r %s
' "$requested_ip"
    } > /etc/network/interfaces

    # Remove known appliance networking hooks/config fragments while leaving
    # Alpine's stock ifup/down machinery intact.
    rm -f         /etc/network/if-up.d/litevmm*         /etc/network/if-down.d/litevmm*         /etc/network/if-up.d/litefwm*         /etc/network/if-down.d/litefwm*         /etc/sysctl.d/litevmm*.conf         /etc/sysctl.d/litefwm*.conf         /etc/sysctl.d/vmapi*.conf         2>/dev/null || true

    ip link set dev "$nic" nomaster >/dev/null 2>&1 || true
    ip link set dev "$nic" up >/dev/null 2>&1 || true

    # Clear stale addresses/routes from the physical NIC before asking the LAN
    # DHCP server for a fresh lease. The host is expected to receive its normal
    # reservation (10.0.1.184 in the current lab).
    ip addr flush dev "$nic" scope global >/dev/null 2>&1 || true
    ip route flush dev "$nic" >/dev/null 2>&1 || true

    killall udhcpc >/dev/null 2>&1 || true
    if command -v udhcpc >/dev/null 2>&1; then
        if [ -n "$requested_ip" ]; then
            udhcpc -i "$nic" -q -n -t 12 -T 2 -r "$requested_ip" >/dev/null 2>&1 ||
                warn "Immediate DHCP renewal for $requested_ip failed; Alpine networking service will retry."
        else
            udhcpc -i "$nic" -q -n -t 12 -T 2 >/dev/null 2>&1 ||
                warn "Immediate DHCP renewal failed; Alpine networking service will retry."
        fi
    fi

    if command -v rc-update >/dev/null 2>&1; then
        rc-update add networking boot >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service networking restart >/dev/null 2>&1 || true
    fi
}

delete_vmapi_bridges() {
    if [ -x /usr/local/bin/netctl ]; then
        for f in /etc/vmapi/bridges/*.conf; do
            [ -f "$f" ] || continue
            name=$(basename "$f" .conf)
            /usr/local/bin/netctl bridge-delete "$name" >/dev/null 2>&1 || true
        done
    fi

    if command -v ip >/dev/null 2>&1; then
        for p in /sys/class/net/vmo-* /sys/class/net/tap[0-9]*; do
            [ -e "$p" ] || continue
            name=$(basename "$p")
            ip link delete dev "$name" >/dev/null 2>&1 || true
        done
    fi
}

delete_overlays() {
    if [ -x /usr/local/bin/overlayctl ]; then
        for f in /etc/vmapi/overlays/*.conf; do
            [ -f "$f" ] || continue
            name=$(basename "$f" .conf)
            /usr/local/bin/overlayctl delete "$name" >/dev/null 2>&1 || true
        done
    fi
}

unmount_vmapi() {
    # Unmount deepest paths first. /proc/mounts escaping is irrelevant for the
    # LiteVMM paths, which do not contain whitespace.
    if [ -r /proc/mounts ]; then
        awk '$2 ~ "^/var/lib/vmapi/" { print $2 }' /proc/mounts 2>/dev/null |
            sort -r 2>/dev/null |
            while IFS= read -r mp; do
                umount "$mp" >/dev/null 2>&1 || umount -l "$mp" >/dev/null 2>&1 || true
            done
    fi

    umount /var/lib/vmapi/backplane/shared/isos >/dev/null 2>&1 || true
    umount /proc/fs/nfsd >/dev/null 2>&1 || true
}

remove_cron_entries() {
    if [ -f /etc/crontabs/root ]; then
        tmp=$(mktemp /tmp/litevmm-cron.XXXXXX)
        awk '!/# vmapi-backup:/' /etc/crontabs/root > "$tmp"
        cat "$tmp" > /etc/crontabs/root
        chmod 0600 /etc/crontabs/root 2>/dev/null || true
        rm -f "$tmp"
    fi
    rm -f /etc/cron.d/vmapi-backup-* 2>/dev/null || true
}

remove_tun_module_line() {
    if [ -f /etc/modules ]; then
        tmp=$(mktemp /tmp/litevmm-modules.XXXXXX)
        awk '$0 != "tun"' /etc/modules > "$tmp"
        cat "$tmp" > /etc/modules
        rm -f "$tmp"
    fi
}

remove_litevmm_binaries() {
    tools='
vmapi vmapi-web-reload vmctl imagectl netctl dockerctl dockerexecctl hostexecctl
logctl docker-imagectl docker-netctl docker-volumectl dockercompoectl
docker-federationctl docker-rootfsctl litevmm-docker litevmm-runc metricsctl
consolectl peerctl vmbackupctl replicationctl registryctl peer-volumectl
backplanectl filectl storagectl overlayctl certctl vmapi-console-gc
vmapi-autostart vmapi-stopall websocat wsvpn
vm-list vm-show vm-status vm-create vm-set vm-start vm-stop vm-shutdown vm-reboot
vm-restart vm-delete vm-disk-add vm-disk-remove vm-disk-resize vm-disk-set
vm-nic-add vm-nic-remove vm-nic-set vm-pci-add vm-pci-remove vm-cloud-init-set
vm-cloud-init-show vm-cloud-init-disable vm-console-info vm-command
metrics-host vm-metrics docker-metrics
docker-list docker-show docker-status docker-create docker-update docker-start
docker-stop docker-restart docker-delete
'
    for name in $tools; do
        rm -f "/usr/local/bin/$name"
    done

    # Only remove /usr/local/bin/docker if it is LiteVMM's federation shim.
    if [ -f /usr/local/bin/docker ] &&
       grep -Fq 'LiteVMM Docker CLI federation shim' /usr/local/bin/docker 2>/dev/null; then
        rm -f /usr/local/bin/docker
    fi

    # Older iterations used GOST. Remove it only when it is accompanied by the
    # LiteVMM share/marker tree or looks like a LiteVMM-managed binary path.
    if [ -f /usr/local/bin/gost ] && [ -d /usr/local/share/litevmm ]; then
        rm -f /usr/local/bin/gost
    fi
}

remove_litefwm_state() {
    for svc in litefwm lighttpd dnsmasq named squid snort haproxy openvpn tailscaled ddclient; do
        service_stop_disable "$svc"
    done

    rm -f         /etc/init.d/litefwm         /etc/sudoers.d/litefwm-web         /usr/local/sbin/apictl         /usr/local/sbin/capturectl         /usr/local/sbin/configctl         /usr/local/sbin/ddnsctl         /usr/local/sbin/dhcpctl         /usr/local/sbin/diagctl         /usr/local/sbin/firewallctl         /usr/local/sbin/fwmctl         /usr/local/sbin/logctl         /usr/local/sbin/metricsctl         /usr/local/sbin/modulecfgctl         /usr/local/sbin/modulectl         /usr/local/sbin/netctl         /usr/local/sbin/setupctl         /usr/local/sbin/webctl         2>/dev/null || true

    rm -rf         /etc/litefwm         /usr/share/litefwm         /usr/lib/litefwm         /var/lib/litefwm         /var/log/litefwm         /run/litefwm         2>/dev/null || true
}

remove_vmapi_account() {
    if command -v deluser >/dev/null 2>&1; then
        deluser vmapi >/dev/null 2>&1 || true
    elif command -v userdel >/dev/null 2>&1; then
        userdel vmapi >/dev/null 2>&1 || true
    fi

    if command -v delgroup >/dev/null 2>&1; then
        delgroup vmapi >/dev/null 2>&1 || true
        delgroup vmapi-admin >/dev/null 2>&1 || true
    elif command -v groupdel >/dev/null 2>&1; then
        groupdel vmapi >/dev/null 2>&1 || true
        groupdel vmapi-admin >/dev/null 2>&1 || true
    fi
}

purge_litevmm_packages() {
    # This is the union of packages currently installed by install.sh on Alpine.
    # apk del removes them from the world set; dependencies are pruned when no
    # remaining package needs them.
    packages='
bash coreutils findutils gawk grep sed shadow util-linux iproute2 iputils curl
openssl sudo tar gzip zip jq fcgiwrap spawn-fcgi lighttpd lighttpd-openrc
lighttpd-mod_auth apache2-utils openssh-client-default
iptables nftables socat kmod tcpdump dnsmasq dnsmasq-openrc bind bind-openrc
openvpn openvpn-openrc tailscale tailscale-openrc squid squid-openrc snort haproxy
haproxy-openrc ddclient ddclient-openrc qemu-img qemu-system-x86_64 ovmf novnc
ttyd xorriso nfs-utils docker docker-openrc docker-cli-compose certbot
'

    remove=''
    for pkg in $packages; do
        [ "$pkg" = sudo ] && [ "$KEEP_SUDO" -eq 1 ] && continue
        if apk info -e "$pkg" >/dev/null 2>&1; then
            remove="$remove $pkg"
        fi
    done

    if [ -n "$remove" ]; then
        # shellcheck disable=SC2086
        apk del --purge $remove || true
    fi
}

PRIMARY_IP=$(select_current_ipv4 || true)
PRIMARY_NIC=$(select_primary_nic) || die "No physical Ethernet interface was detected"
log "Primary physical NIC selected for DHCP restore: $PRIMARY_NIC"
[ -z "$PRIMARY_IP" ] || log "Current management IPv4 will be requested from DHCP after reset: $PRIMARY_IP"

log "Stopping LiteVMM/LiteFWM workloads and services"

if [ -x /usr/local/bin/vmapi-stopall ]; then
    /usr/local/bin/vmapi-stopall >/dev/null 2>&1 || true
fi
if [ -x /usr/local/bin/replicationctl ]; then
    /usr/local/bin/replicationctl suspend >/dev/null 2>&1 || true
fi
if [ -x /usr/local/bin/backplanectl ]; then
    /usr/local/bin/backplanectl suspend >/dev/null 2>&1 || true
fi

delete_overlays
delete_vmapi_bridges

for svc in \
    vmapi-replication vmapi-overlay vmapi-network vmapi-autostart \
    vmapi-console-gc ttyd-vmapi ttyd-host-vmapi \
    vmapi-backplane vmapi-backplane-server fcgiwrap-vmapi \
    websockify-vmapi docker lighttpd litefwm dnsmasq named squid snort haproxy \
    openvpn tailscaled ddclient nfs nfs-server
do
    service_stop_disable "$svc"
done

# Kill residue from interrupted iterations. This host reset is intentionally
# dedicated-host destructive.
for proc in \
    qemu-system-x86_64 qemu-kvm wsvpn websocat gost ttyd fcgiwrap lighttpd \
    dockerd containerd
do
    killall "$proc" >/dev/null 2>&1 || true
done

if command -v exportfs >/dev/null 2>&1; then
    exportfs -u '127.0.0.1:/var/lib/vmapi/backplane' >/dev/null 2>&1 || true
fi
if command -v rpc.nfsd >/dev/null 2>&1; then
    rpc.nfsd 0 >/dev/null 2>&1 || true
fi

unmount_vmapi
remove_cron_entries
remove_tun_module_line
remove_litefwm_state

log "Resetting firewall and network devices"
flush_firewall_state
delete_nonphysical_links
restore_alpine_dhcp "$PRIMARY_NIC" "$PRIMARY_IP"

log "Removing LiteVMM OpenRC services, binaries and configuration"

rm -f \
    /etc/init.d/fcgiwrap-vmapi \
    /etc/init.d/vmapi-autostart \
    /etc/init.d/vmapi-console-gc \
    /etc/init.d/ttyd-vmapi \
    /etc/init.d/ttyd-host-vmapi \
    /etc/init.d/vmapi-overlay \
    /etc/init.d/vmapi-network \
    /etc/init.d/vmapi-replication \
    /etc/init.d/vmapi-backplane \
    /etc/init.d/vmapi-backplane-server \
    /etc/init.d/websockify-vmapi \
    /etc/sudoers.d/vmapi \
    /etc/vmapi-peer.htpasswd \
    /etc/pam.d/nginx-vmapi

remove_litevmm_binaries

rm -rf \
    /etc/vmapi \
    /usr/local/lib/vmapi \
    /usr/local/share/litevmm \
    /usr/lib/vmapi \
    /usr/share/vmapi \
    /run/vmapi \
     /run/vmapi-overlay \
    /run/vmapi-backplane \
    /var/lib/vmapi \
    /var/log/vmapi

# These stacks are installed only to support LiteVMM on the dedicated Alpine
# development VM. Removing their state prevents one test iteration from
# influencing the next.
rm -rf \
    /etc/lighttpd \
    /var/log/lighttpd \
    /etc/docker \
    /var/lib/docker \
    /var/lib/containerd \
    /run/docker \
    /run/containerd \
    /etc/qemu \
    /etc/letsencrypt \
    /var/lib/letsencrypt \
    /var/log/letsencrypt \
    /var/lib/nfs \
    /etc/cni \
    /var/lib/cni

remove_vmapi_account

log "Ensuring the packages that must survive are present"

keep='alpine-base openssh ca-certificates'
[ "$KEEP_GIT" -eq 1 ] && keep="$keep git"
[ "$KEEP_SUDO" -eq 1 ] && keep="$keep sudo"

# shellcheck disable=SC2086
apk add --no-cache $keep

log "Purging packages installed by the LiteVMM Alpine installer"
purge_litevmm_packages

# A packae purge may have changed dependency choices. Reassert the minimal keep
# set once more and make sure SSH remains enabled.
# shellcheck disable=SC2086
apk add --no-cache $keep

if command -v rc-update >/dev/null 2>&1; then
    rc-update add sshd default >/dev/null 2>&1 || true
fi
if command -v rc-service >/dev/null 2>&1; then
    rc-service sshd start >/dev/null 2>&1 || true
fi

rm -rf /var/cache/apk/* 2>/dev/null || true

log "Reset complete"
printf 'Kept packages: Alpine base, OpenSSH, CA certificates'
[ "$KEEP_GIT" -eq 1 ] && printf ', Git'
[ "$KEEP_SUDO" -eq 1 ] && printf ', sudo'
printf '.\n'
printf 'LiteVMM/LiteFWM installed state and package footprint have been removed.\n'
printf 'The primary NIC was restored to Alpine DHCP networking.\n'
printf 'The source checkout was intentionally left in place so install.sh can be run again.\n'
