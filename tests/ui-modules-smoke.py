#!/usr/bin/env python3
"""Headless Chrome smoke of module routes with strictly mocked read-only API."""
import http.server
import json
import pathlib
import subprocess
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent / "www"
MODULES = [
    {"id": "bind", "name": "BIND DNS", "description": "Authoritative DNS", "installed": True, "core": False, "packages": ["bind"]},
    {"id": "dnsmasq", "name": "DNSMasq", "description": "LAN DNS and DHCP", "installed": True, "core": True, "packages": ["dnsmasq"]},
    {"id": "ddns", "name": "Dynamic DNS", "description": "DDNS updates", "installed": True, "core": False, "packages": ["inadyn"]},
    {"id": "openvpn", "name": "OpenVPN", "description": "VPN access", "installed": True, "core": False, "packages": ["openvpn"]},
    {"id": "ipsec", "name": "IPsec (strongSwan)", "description": "IKEv2 site tunnels", "installed": True, "core": False, "packages": ["strongswan","strongswan-openrc"]},
]
ADDONS = [
    ("suricata","Suricata IDS/IPS","security"),("geoip","GeoIP Blocking","security"),
    ("crowdsec","CrowdSec","security"),("wireguard","WireGuard VPN","vpn"),
    ("cloudflared","Cloudflare Tunnel","connectivity"),("multiwan","Multi-WAN Failover","network"),
    ("mdns","mDNS Repeater","network"),("captive","Captive Portal","network"),
    ("frr","BGP / FRRouting","routing"),
]
for addon_id, name, category in ADDONS:
    MODULES.append({"id": addon_id, "name": name, "description": name + " integration",
                    "installed": True, "core": False, "packages": []})
BIND = {"running": True, "configured": True, "zones": [
    {"name": "example.net", "serial": "2026110301", "records": []}],
    "listenAddresses": ["10.0.1.199"], "recursion": True,
    "recursiveClients": ["10.0.0.0/8"], "forwarders": ["1.1.1.3", "1.0.0.3"],
    "forwardMode": "only", "dnssecValidation": "auto", "maxCacheTtl": 7200}
STATES = {
    "bind": BIND, "dnsmasq": {"running": True, "configured": True, "dnsEnabled": False},
    "ddns": {"running": True, "configured": True, "provider":"default@opendns.com","hostnames":["mynetwork"],"period":300,"interface":"", "username":"opendns-migrated","credentialConfigured":True, "custom":{}, "cloudflare":{"configured":True, "enabled":True, "scheduleMinutes":15, "credentialConfigured":True, "email":"admin@example.net", "zone":"blaize.net", "hostnames":["cloud.blaize.net","home.blaize.net"],"last":{"checkedAt":"2026-11-03T15:22:43Z","publicIPv4":"108.255.76.134"}}},
    "openvpn": {"running": False, "configured": False, "clients": [],
        "clientTunnels":[{"id":"office","mode":"site-to-site","remoteHost":"vpn.example.net",
                          "interface":"tun2","localSubnet":"10.1.0.0/24","remoteSubnet":"10.66.0.0/24","running":False}],
        "sitePeers":[{"id":"branch","localSubnet":"10.1.0.0/24","remoteSubnet":"10.88.0.0/24"}]},
    "ipsec": {"running":False,"configured":True,"tunnels":[
        {"id":"branch","mode":"site-to-site","peer":"198.51.100.24",
         "localSubnet":"10.1.0.0/24","remoteSubnet":"10.44.0.0/24",
         "localId":"fw.example.net","remoteId":"branch.example.net",
         "enabled":False,"established":False,"credentialConfigured":True}]}
}
for addon_id, name, category in ADDONS:
    STATES[addon_id] = {"running": False, "configured": True,
                        "settings":{"enabled": False, "credentialConfigured":False}}
SYSTEM = {"hostname": "testfw", "version": "2.2.13-dev", "resolvers": ["1.1.1.1"],
          "management": {"clientInterface": "eth1", "port": 80, "access": ["eth1"]},
          "ssh": {"enabled": True, "port": 22},
          "logging": {"remoteEnabled": False,"server":"","port":514,"localEnabled":True,"serviceRunning":True},
          "telemetry": {"prometheus": True, "otlpEnabled": False,
                        "endpoint": "", "intervalMinutes": 5, "tokenConfigured": False},
"memory": {"availableKb": 10, "totalKb": 100}}


class MockHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT), **kw)

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/probe-api-keys"):
            page = (ROOT / "index.html").read_text()
            probe = """<script>
              setTimeout(() => {
                const panel=[...document.querySelectorAll('#view .card')]
                  .find(el => el.textContent.includes('API keys'));
                const create=panel && [...panel.querySelectorAll('button')]
                  .find(b => b.textContent.trim()==='Create API key');
                if(create) create.click();
                const info={
                  title:document.getElementById('dlgTitle')?.textContent,
                  inputName:document.getElementById('f_name')?.tagName,
                  scope:[...document.querySelectorAll('#f_scope option')].map(x=>x.value),
                  expiration:[...document.querySelectorAll('#f_expiresInDays option')].map(x=>x.value),
                  revoke:panel?.textContent.includes('Revoke'),
                  docs:panel?.querySelector('a[href="/docs/api.html"]')!=null
                };
                const output=document.createElement('pre');output.id='api-key-ui-probe';
                output.textContent=JSON.stringify(info);document.body.append(output);
              },1400);
            </script>"""
            data=page.replace('</body>',probe+'</body>').encode()
            self.send_response(200)
            self.send_header('Content-Type','text/html')
            self.send_header('Content-Length',str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith("/probe-cloudflare"):
            html = (ROOT / "index.html").read_text()
            probe = """<script>
                setTimeout(() => {
                  const card = [...document.querySelectorAll('#view .card')]
                    .find(c => c.textContent.includes('Cloudflare DNS (pfSense migration)'));
                  const configure = card && [...card.querySelectorAll('button')]
                    .find(b => b.textContent.trim() === 'Configure');
                  if (configure) configure.click();
                  const ids = [...document.querySelectorAll('#dlgBody input, #dlgBody select')]
                    .map(el => el.id);
                  const probe = {title:document.getElementById('dlgTitle').textContent,
                    inputs:ids, zone:document.getElementById('f_zone')?.value,
                    email:document.getElementById('f_email')?.value,
                    apiKeyType:document.getElementById('f_apiKey')?.type,
                    apiKeyValue:document.getElementById('f_apiKey')?.value,
                    interval:document.getElementById('f_scheduleMinutes')?.value,
                    enabled:document.getElementById('f_enabled')?.checked,
                    note:document.getElementById('dlgBody')?.textContent.includes('read-only')};
                  const el = document.createElement('pre'); el.id='cloudflare-probe';
                  el.textContent=JSON.stringify(probe);document.body.append(el);
                }, 1400);
            </script>"""
            content = html.replace('</body>', probe + '</body>').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
        if self.path.startswith("/api/"):
            endpoint = self.path[5:]
            if endpoint == "modules":
                data = {"modules": MODULES}
            elif endpoint.startswith("modules/"):
                mid = endpoint[8:]
                data = {"modules": [dict(next(m for m in MODULES if m["id"] == mid), state=STATES[mid])]}
            elif endpoint == "dns":
                data = {"dns": {"domain": "lan", "upstream": ["1.1.1.3", "1.0.0.3"], "hosts": []}}
            elif endpoint == "segments":
                data = {"interfaces": [{"name": "eth1", "kind": "physical", "role": "lan",
                                        "label": "LAN", "addresses": ["10.0.1.199/24"]}]}
            elif endpoint == "system/api-keys":
                data = {"apiKeys": [
                    {"id":"a"*20,"name":"Monitoring","scope":"read",
                     "createdAt":1793736000,"expiresAt":1796414400,"expired":False}]}
            elif endpoint in ("system", "overview"):
                data = {"system": SYSTEM}
            elif endpoint == "identity":
                data = {"hostname": "testfw", "version": "2.2.13-dev"}
            else:
                self.send_error(404)
                return
            payload = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            super().do_GET()


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = "http://127.0.0.1:" + str(server.server_port)
    try:
        for path, expected in [
            ("modules", ["BIND DNS", "DNSMasq", "Dynamic DNS", "OpenVPN", "Configure"]),
            ("system", ["Alpine system packages", "Check packages", "Apply package updates", "Software updates", "Telemetry export", "OTLP",
                        "API keys", "Create API key", "Monitoring", "Revoke", "API reference", "CLI manual"]),
            ("module-bind", ["BIND authoritative zones", "Manage records", "Cloudflare"]),
            ("module-dnsmasq", ["DNSMasq DNS engine", "Upstream servers", "DNS resolver (dnsmasq)"]),
            ("module-ddns", ["Dynamic DNS", "Configure Inadyn provider", "Cloudflare DNS (pfSense migration)", "cloud.blaize.net", "home.blaize.net", "Check records"]),
            ("module-openvpn", ["OpenVPN routed server", "OpenVPN clients", "OpenVPN client tunnels", "Site-to-site peers", "office", "branch"]),
            ("module-ipsec", ["IPsec service", "IPsec site-to-site tunnels", "branch", "198.51.100.24", "Add site-to-site tunnel"]),
            ("module-suricata", ["Suricata IDS/IPS", "Inspection settings", "Rule sources", "Signature controls", "Add HTTPS source", "Upload .rules"]),
            ("module-geoip", ["GeoIP Blocking", "Save selected countries", "Search countries", "Select shown", "Clear all", "Argentina", "United States"]),
            ("module-crowdsec", ["CrowdSec", "Configure"]),
            ("module-wireguard", ["WireGuard VPN", "Server settings", "VPN peers", "Add peer"]),
            ("module-cloudflared", ["Cloudflare Tunnel", "Configure"]),
            ("module-multiwan", ["Multi-WAN Failover", "Add WAN uplink", "Save WAN configuration"]),
            ("module-mdns", ["mDNS Repeater", "Configure"]),
            ("module-captive", ["Captive Portal", "Configure"]),
            ("module-frr", ["BGP / FRRouting", "BGP neighbors", "Advertised prefixes"]),
        ]:
            run = subprocess.run(
                ["google-chrome", "--headless=new", "--no-sandbox", "--disable-gpu",
                 "--disable-dev-shm-usage", "--no-first-run",
                 "--disable-background-networking", "--disable-extensions", "--disable-component-update",
                 "--virtual-time-budget=2500",
                 "--dump-dom", url + "/#" + path],
                capture_output=True, text=True, timeout=75)
            html = run.stdout
            if run.returncode or any(x not in html for x in expected) or "Could not read live state" in html:
                print('UI_ERROR_CONTEXT:', html[html.find('id="view"')-100:html.find('id="view"')+1600], flush=True)
                raise AssertionError(f"UI smoke failed for #{path}: code={run.returncode}, "
                                     f"missing={[x for x in expected if x not in html]}, "
                                     f"stderr={run.stderr[-400:]}, html={html[-700:]}")
            print("PASS: Chrome rendered #" + path)
        run = subprocess.run(
            ["google-chrome", "--headless=new", "--no-sandbox", "--disable-gpu",
             "--disable-dev-shm-usage", "--no-first-run",
             "--disable-background-networking", "--disable-extensions", "--disable-component-update",
             "--virtual-time-budget=3500",
             "--dump-dom", url + "/probe-cloudflare#module-ddns"],
            capture_output=True, text=True, timeout=75)
        import html as html_lib
        import re
        match = re.search(r'<pre id="cloudflare-probe">(.*?)</pre>', run.stdout, re.S)
        if not match:
            raise AssertionError('Cloudflare Configure button did not open the editable form: ' + run.stdout[-1200:])
        probe = json.loads(html_lib.unescape(match.group(1)))
        expected = {'f_zone','f_hostnames','f_email','f_apiKey','f_scheduleMinutes','f_enabled'}
        assert probe['title'] == 'Configure Cloudflare Dynamic DNS', probe
        assert expected.issubset(set(probe['inputs'])), probe
        assert probe['zone'] == 'blaize.net' and probe['email'] == 'admin@example.net', probe
        assert probe['apiKeyType'] == 'password' and probe['apiKeyValue'] == '', probe
        assert probe['interval'] == '15' and probe['enabled'] is True and probe['note'] is True, probe
        print('PASS: Chrome opened Cloudflare settings with six editable controls and protected credential')
        run = subprocess.run(
            ["google-chrome", "--headless=new", "--no-sandbox", "--disable-gpu",
             "--disable-dev-shm-usage", "--no-first-run",
             "--disable-background-networking", "--disable-extensions",
             "--virtual-time-budget=3500", "--dump-dom", url + "/probe-api-keys#system"],
            capture_output=True, text=True, timeout=75)
        import re
        match = re.search(r'<pre id="api-key-ui-probe">(.*?)</pre>',run.stdout,re.S)
        if not match:
            raise AssertionError("API key create button did not open: " + run.stdout[-1200:])
        probe=json.loads(html_lib.unescape(match.group(1)))
        assert probe["title"]=="Create API key",probe
        assert probe["inputName"]=="INPUT",probe
        assert probe["scope"]==["read","admin"],probe
        assert probe["expiration"]==["7","30","90","365","0"],probe
        assert probe["revoke"] and probe["docs"],probe
        print('PASS: Chrome opened API key create form, expiry/scope choices and revoke/docs links')
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
