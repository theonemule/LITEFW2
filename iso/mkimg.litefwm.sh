# LiteFWM appliance installer ISO profile for Alpine mkimage.
profile_litefwm() {
	profile_standard
	profile_abbrev="litefwm"
	title="LiteFW $(cat "$LITEFWM_SOURCE/VERSION")"
	desc="LiteFW firewall appliance - Alpine Linux base."
	arch="x86_64"
	hostname="litefwm"
	syslinux_serial="0 115200"
	kernel_cmdline="${kernel_cmdline:-} console=tty0 console=ttyS0,115200"
	apkovl="scripts/genapkovl-litefwm.sh"

	# Everything required by the base LiteFWM appliance is carried on the ISO so
	# a sys-mode Alpine install can complete with no network connection.
	# Optional supported modules are also carried in the ISO APK repository, but
	# they are intentionally not part of /etc/apk/world and are not installed
	# unless the operator enables the module.
	apks="$apks \
		ifupdown-ng iproute2 iptables dnsmasq jq util-linux openssh \
		linux-lts syslinux grub-bios grub-efi dosfstools e2fsprogs linux-firmware-other \
		lighttpd lighttpd-mod_auth apache2-utils sudo busybox-openrc \
		bind bind-tools bind-openrc \
		openvpn openvpn-openrc easy-rsa \
		inadyn inadyn-openrc"
}
