# LiteFW2 nftables migration — local ISO QA report

**Note:** The locally tested ISO captured the nftables source before the version-only bump from 2.2.24 to 2.2.25. The v2.2.25 release ISO must be rebuilt and validated by the GitHub Actions release workflow.

**Date:** November 14, 2026
**Branch:** `feature/nftables-iproute2` (isolated development worktree)
**Status:** source implemented, built and locally verified; **not deployed or released**.

## Tested ISO

- Path on development machine: `dist/alpine-litefwm-v3.24-x86_64.iso`
- Alpine: 3.24 x86_64
- File size: **548,405,248 bytes**
- SHA-256: `863957e70509a60ed5eb02dd8e2cbfe06c0d5d7ee1bae0715cb7e76f6ab49fb8`
- Build exit status: **0** (`qa-results/iso-build.log`)

## Evidence and gates

| Test group | Status | Evidence |
| --- | --- | --- |
| Reproducible ISO build in disposable Alpine container | PASS | `qa-results/iso-build.log` |
| QEMU boot and offline installation (no NIC/network) | PASS | `qa-results/qemu/offline.log` |
| Reboot from installed disk, runtime/UI/CLI/boot services intact | PASS | `qa-results/qemu/offline.log` |
| Live ISO WAN/LAN packet path and TCP port-forward | PASS | `qa-results/qemu/wanlan.log` |
| Installed-disk WAN/LAN packet path and TCP port-forward | PASS | `qa-results/qemu/installed-wanlan.log` |
| Real packet precedence and allow recovery | PASS | both WAN/LAN traces |
| LAN-only HTTP Basic UI/API, WAN denial | PASS | both WAN/LAN traces |
| HTTP API create/edit/delete structured host rule | PASS | both WAN/LAN traces |
| Native nftables, modules, auth, VPN, BGP, GeoIP integrations | PASS: **11/11** | `qa-results/local-regressions.log` |
| Source, package, SSH, module, web safety tests | PASS: **10/10** | `qa-results/source-suite.log` |
| Web UI wizard rendered and exercised in Chromium | PASS | `qa-results/browser-smoke.log` |
| Legacy iptables migration rejected; safe application-only upgrade | PASS | `qa-results/inplace-upgrade.log` |
| Optional cloudflared/openNDS install + uninstall | PASS | `qa-results/vendor-modules.log` |
| Tailscale, inadyn and Cloudflare DDNS integration | PASS | `qa-results/additional-modules.log` |
| Overlay root permissions and protected sudoers | PASS | `tests/iso-overlay-permissions.sh` |
| Generated OpenAPI/docs/CLI help consistent with schema | PASS | `python3 tools/render-api-docs.py --check` |
| Build package/CLI checksum/manifest validation | PASS | `tests/runtime-release-package.sh` |

Run the complete local ISO test harness again with:

    sh tools/test-iso-local.sh dist/alpine-litefwm-v3.24-x86_64.iso both

Run native kernel, service and packet tests with:

    bash tests/run-local-regressions.sh

The local harness copies source and ISO into an isolated Docker/QEMU
container; it does not install or modify the developer machine's firewall.
KVM is used when available; software emulation remains a fallback.

## Defects caught and addressed during this QA

- ISO builder expected an accessible host bind mount, incompatible with the
  development environment's remote Docker daemon. Source/ISO transfer now
  uses Docker copy/streamed archives.
- Alpine `apkovl` tar included a `0700` temporary root-directory entry,
  preventing non-root lighttpd from accessing files. The packaged `/` mode
  is now `0755`, with sensitive files retaining restrictive permissions.
- WAN/LAN HTTP fixture invoked a missing `busybox httpd` applet rather than
  the `busybox-extras` `httpd` command. The harness now requires working
  fixture servers before booting the VM.
- Live-media and installed-disk log ownership differs; tests now verify
  actual service-user access and protection from unrelated users.
- Generated API documentation/CLI help was stale. It is generated and
  validated from the structured OpenAPI schema and firewall guide.

## Out of scope for this local candidate

- No live/router/firewall upgrade or cutover. Converting a production
  iptables ruleset is explicitly refused until a console-backed migration
  procedure is reviewed and approved.
- No actual physical NIC/hardware drivers tested.
- The optional openNDS binary installs and uninstalls, but a full
  real-guest captive portal session was not exercised.
- No Git push, merge, tag, ISO publication or release deployment.
