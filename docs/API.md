# LiteFW HTTP API Reference

OpenAPI 3.1 · Version 2.2.23

Base URL: /api. Authentication: HTTP Basic or X-API-Key.
All POST mutations require X-LiteFWM: 1 and JSON, except the binary upgrade upload.
API keys have read or admin scope; sensitive key/password/management operations require Basic.

| Method | Endpoint | Description |
| --- | --- | --- |
| GET | /api/dhcp | DHCP servers, leases and reservations |
| POST | /api/dhcp/reservations/add | Add DHCP reservation |
| POST | /api/dhcp/reservations/delete | Delete DHCP reservation |
| POST | /api/dhcp/server/set | Configure DHCP |
| GET | /api/dns | DNS settings |
| POST | /api/dns/set | Configure DNS |
| GET | /api/firewall | Current managed firewall rules |
| POST | /api/firewall/batch | Stage a firewall ruleset transaction |
| POST | /api/firewall/confirm | Confirm staged firewall rules |
| POST | /api/firewall/rules/add | Add firewall rule |
| POST | /api/firewall/rules/delete | Delete firewall rule |
| POST | /api/firewall/rules/move | Move firewall rule |
| POST | /api/firewall/rules/update | Edit firewall rule |
| GET | /api/identity | Current authenticated API identity |
| GET | /api/interfaces | Interfaces and addresses |
| POST | /api/interfaces/bridge/addmember | Add bridge member |
| POST | /api/interfaces/bridge/create | Create bridge |
| POST | /api/interfaces/bridge/delete | Remove bridge |
| POST | /api/interfaces/bridge/delmember | Remove bridge member |
| POST | /api/interfaces/bridge/portvlans | Configure bridge VLAN memberships |
| POST | /api/interfaces/bridge/set | Update bridge |
| POST | /api/interfaces/iface/set | Change physical interface |
| POST | /api/interfaces/vlan/create | Create VLAN |
| POST | /api/interfaces/vlan/delete | Remove VLAN |
| GET | /api/modules | Optional module catalog and installation status |
| POST | /api/modules/bind/recordadd | Bind — recordadd |
| POST | /api/modules/bind/recordchange | Bind — recordchange |
| POST | /api/modules/bind/recorddelete | Bind — recorddelete |
| POST | /api/modules/bind/service | Bind — service |
| POST | /api/modules/bind/settings | Bind — settings |
| POST | /api/modules/bind/zoneadd | Bind — zoneadd |
| POST | /api/modules/bind/zonedelete | Bind — zonedelete |
| POST | /api/modules/bind/zoneread | Bind — zoneread |
| POST | /api/modules/bind/zonerecords | Bind — zonerecords |
| POST | /api/modules/bind/zonewrite | Bind — zonewrite |
| POST | /api/modules/captive/configure | Captive — configure |
| POST | /api/modules/captive/service | Captive — service |
| POST | /api/modules/cloudflared/configure | Cloudflared — configure |
| POST | /api/modules/cloudflared/service | Cloudflared — service |
| POST | /api/modules/crowdsec/configure | Crowdsec — configure |
| POST | /api/modules/crowdsec/decisionssync | Crowdsec — decisionssync |
| POST | /api/modules/crowdsec/service | Crowdsec — service |
| POST | /api/modules/ddns/cfcheck | Ddns — cfcheck |
| POST | /api/modules/ddns/cfconfigure | Ddns — cfconfigure |
| POST | /api/modules/ddns/cfupdate | Ddns — cfupdate |
| POST | /api/modules/ddns/configure | Ddns — configure |
| POST | /api/modules/ddns/force | Ddns — force |
| POST | /api/modules/ddns/service | Ddns — service |
| POST | /api/modules/frr/configure | Frr — configure |
| POST | /api/modules/frr/service | Frr — service |
| POST | /api/modules/geoip/configure | Geoip — configure |
| POST | /api/modules/geoip/refresh | Geoip — refresh |
| POST | /api/modules/geoip/service | Geoip — service |
| POST | /api/modules/ipsec/service | Ipsec — service |
| POST | /api/modules/ipsec/tunneldelete | Ipsec — tunneldelete |
| POST | /api/modules/ipsec/tunnelset | Ipsec — tunnelset |
| POST | /api/modules/ipsec/tunnelstart | Ipsec — tunnelstart |
| POST | /api/modules/ipsec/tunnelstop | Ipsec — tunnelstop |
| POST | /api/modules/mdns/configure | Mdns — configure |
| POST | /api/modules/mdns/service | Mdns — service |
| POST | /api/modules/multiwan/configure | Multiwan — configure |
| POST | /api/modules/multiwan/service | Multiwan — service |
| POST | /api/modules/openvpn/clientadd | Openvpn — clientadd |
| POST | /api/modules/openvpn/clientrevoke | Openvpn — clientrevoke |
| POST | /api/modules/openvpn/instanceadd | Openvpn — instanceadd |
| POST | /api/modules/openvpn/instancedelete | Openvpn — instancedelete |
| POST | /api/modules/openvpn/instanceservice | Openvpn — instanceservice |
| POST | /api/modules/openvpn/profile | Openvpn — profile |
| POST | /api/modules/openvpn/server | Openvpn — server |
| POST | /api/modules/openvpn/service | Openvpn — service |
| POST | /api/modules/openvpn/sitepeeradd | Openvpn — sitepeeradd |
| POST | /api/modules/openvpn/sitepeerdelete | Openvpn — sitepeerdelete |
| POST | /api/modules/suricata/configure | Suricata — configure |
| POST | /api/modules/suricata/ruleenable | Suricata — ruleenable |
| POST | /api/modules/suricata/rulesexport | Suricata — rulesexport |
| POST | /api/modules/suricata/rulesupdate | Suricata — rulesupdate |
| POST | /api/modules/suricata/rulesupload | Suricata — rulesupload |
| POST | /api/modules/suricata/service | Suricata — service |
| POST | /api/modules/suricata/sourceenable | Suricata — sourceenable |
| POST | /api/modules/suricata/sourcerefresh | Suricata — sourcerefresh |
| POST | /api/modules/suricata/sourceremove | Suricata — sourceremove |
| POST | /api/modules/suricata/sourceset | Suricata — sourceset |
| POST | /api/modules/wireguard/clientprofile | Wireguard — clientprofile |
| POST | /api/modules/wireguard/configure | Wireguard — configure |
| POST | /api/modules/wireguard/peerenable | Wireguard — peerenable |
| POST | /api/modules/wireguard/peerremove | Wireguard — peerremove |
| POST | /api/modules/wireguard/peerset | Wireguard — peerset |
| POST | /api/modules/wireguard/service | Wireguard — service |
| GET | /api/modules/{id} | Specific module and configuration |
| POST | /api/modules/{id}/install | Install an optional module |
| POST | /api/modules/{id}/remove | Remove an optional module |
| POST | /api/op/{operation} | Legacy operation dispatcher |
| GET | /api/overview | Appliance summary |
| GET | /api/port-forwards | Port forwards |
| POST | /api/port-forwards/add | Create port forward |
| POST | /api/port-forwards/delete | Delete port forward |
| POST | /api/port-forwards/update | Update port forward |
| GET | /api/segments | Network segments and DHCP state |
| POST | /api/segments/set | Configure network segments |
| GET | /api/state | Legacy combined state snapshot |
| GET | /api/system | Appliance settings and status |
| GET | /api/system/api-keys | List API key metadata (no secret material) |
| POST | /api/system/api-keys/create | Create an API key (secret displayed once; Basic only) |
| POST | /api/system/api-keys/revoke | Revoke an API key immediately (Basic only) |
| POST | /api/system/diagnostics/lookup | DNS lookup |
| POST | /api/system/diagnostics/ping | Ping test |
| POST | /api/system/logging | Configure logging |
| POST | /api/system/management | Configure management access (Basic credentials only) |
| POST | /api/system/packages/check | Check Alpine package updates |
| POST | /api/system/packages/upgrade | Upgrade Alpine packages |
| POST | /api/system/password | Change administrator password (Basic credentials only) |
| POST | /api/system/set | Change general system settings |
| POST | /api/system/telemetry | Configure telemetry exporters |
| POST | /api/system/updates/check | Check LiteFW releases |
| POST | /api/system/updates/install | Install verified LiteFW runtime release |
| POST | /api/system/updates/upload | Upload runtime bundle |
| GET | /api/telemetry | Telemetry exporter settings |
| GET | /api/telemetry/metrics | Prometheus text metrics |

The canonical source is docs/openapi.json.
