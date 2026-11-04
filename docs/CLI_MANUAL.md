# LiteFW CLI Manual

The standalone litefw script is a POSIX-shell client for LiteFW. It needs
curl and base64, with optional jq for formatted JSON output.

## Installation and login
Download litefw from the matching GitHub release and run:

    chmod +x litefw
    ./litefw login https://firewall.example.net --api-key
    ./litefw whoami
    ./litefw get /system

The API key is requested interactively; it is not an argument. To use
existing Basic credentials instead:

    litefw login https://firewall.example.net --basic admin

For appliances offering only HTTP on a **trusted LAN**, explicit consent
is required:

    litefw login http://10.0.1.199 --api-key --allow-http

HTTP is unencrypted. Prefer HTTPS or a VPN when transmitting API keys or passwords.

## Commands
- **litefw login URL --api-key**: Prompt for API key and verify authentication.
- **litefw login URL --basic USER**: Prompt for Basic password and verify.
- **litefw logout**: Delete locally stored credentials.
- **litefw whoami**: Read appliance hostname and version.
- **litefw get /RESOURCE**: GET any documented resource.
- **litefw post /RESOURCE JSON**: POST JSON to a resource.
- **litefw post /RESOURCE @file.json**: POST a JSON file.
- **litefw post /RESOURCE -**: POST JSON received on stdin.
- **litefw op family.action JSON**: Use a compatibility controller operation.
- **litefw module show|install|remove ID**: Inspect or manage optional modules.
- **litefw module start|stop|restart ID**: Manage module services.
- **litefw upload FILE.tar.gz**: Upload a runtime archive using the binary
  upgrade endpoint; validate it before using on a production firewall.
- **litefw api**: List method/path pairs generated from OpenAPI.
- **litefw help**: Print this embedded manual and examples.

Local credentials are saved in the user configuration directory, usually
~/.config/litefw/config, with permissions 0600. Protect this workstation.
They are never passed as command-line arguments to curl. Use litefw logout
or revoke the key from the appliance when finished.

## Examples

    litefw get /modules/tailscale
    litefw module install tailscale
    litefw post /modules/tailscale/configure '{"hostname":"litefw-edge","acceptRoutes":false,"advertiseRoutes":[]}'
    litefw get /modules/wireguard
    litefw module install geoip
    litefw post /modules/geoip/configure '{"countries":["ru","cn"],"enabled":false}'
    litefw post /modules/geoip/refresh '{}'
    litefw op upgrade.check '{}'
    litefw post /firewall/rules/add @rule.json

## API details
All endpoints are under /api. GET reads state. POST changes configuration and
sends Content-Type: application/json and X-LiteFWM: 1. Errors return non-2xx
HTTP statuses and a JSON error. The CLI exits nonzero on those failures.

Key management endpoints require Basic credentials, even when an API key has
Administrator permissions. Read-only keys cannot perform POST operations.

See [API reference](api.html) for all operations and the machine-readable
[OpenAPI specification](openapi.json) for client generation.
