# LiteFW modules

Modules are defined in the Git-tracked modules/manifest.json. It contains a
version, Alpine package names, a core (non-removable) flag, and relative paths
to bundled module.sh, install.sh and uninstall.sh scripts. The runtime updater
and installer package this manifest with the module scripts; they do not
fetch or execute remote scripts or install from an unaudited plugin store.

Native executable, OpenRC service and configuration files are the source of
truth for a module's status. A successful script exit alone does not mean
that a module installed successfully. The API rechecks native state after
the installer returns, and reports useful errors if verification fails.

To add an optional module: add its entry to the manifest, implement its
three scripts and required meta/installed/snapshot/firewall actions, expose
the configuration API and dedicated UI page, and add contract tests.
Publish through the usual reviewed LiteFW runtime and ISO release workflow.

## DNS engines

DNSMasq is an always-installed, non-removable core module because it is
used for DHCP. Its DNS listener can be disabled while BIND9 handles
authoritative zones and recursive forwarding. The two engines have separate
configuration pages and independently select upstream resolver providers or
custom servers. Switching back to DNSMasq stops BIND, releasing DNS port 53
without deleting BIND zone files or changing DHCP configuration.

The BIND visual record editor loads even imported zone records with the native
named-compilezone parser. Regular DNS records can be added, edited and removed
with a table and forms. Editing an imported record converts the zone to
canonical BIND format (so source comments/formatting may change), first taking
a backup; all edits use checksums, zone validation and rollback on failures.
The advanced raw source editor remains for specialized zone syntax.

## Dynamic DNS troubleshooting

Inadyn needs the inadyn and inadyn-openrc Alpine packages, available in the
community repository or in the optional packages on the LiteFW installation
ISO. The installer now surfaces Alpine APK errors and verifies both the
inadyn executable and the OpenRC service file before showing success.
A successful installation is not equivalent to configured provider credentials
or a successful public DNS update.

Check repositories and package availability using:
    apk policy inadyn inadyn-openrc
Check the service using:
    rc-service inadyn status
Configure a provider and hostname via Modules > Dynamic DNS.
