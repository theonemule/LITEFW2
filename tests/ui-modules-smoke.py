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
]
BIND = {"running": True, "configured": True, "zones": [
    {"name": "example.net", "serial": "2026110301", "records": []}],
    "listenAddresses": ["10.0.1.199"], "recursion": True,
    "recursiveClients": ["10.0.0.0/8"], "forwarders": ["1.1.1.3", "1.0.0.3"],
    "forwardMode": "only", "dnssecValidation": "auto", "maxCacheTtl": 7200}
STATES = {
    "bind": BIND, "dnsmasq": {"running": True, "configured": True, "dnsEnabled": False},
    "ddns": {"running": True, "configured": True, "provider":"default@opendns.com","hostnames":["mynetwork"],"period":300,"interface":"", "username":"opendns-migrated","credentialConfigured":True, "custom":{}, "cloudflare":{"configured":True, "enabled":True, "scheduleMinutes":15, "credentialConfigured":True, "email":"admin@example.net", "zone":"blaize.net", "hostnames":["cloud.blaize.net","home.blaize.net"],"last":{"checkedAt":"2026-11-03T15:22:43Z","publicIPv4":"108.255.76.134"}}},
    "openvpn": {"running": False, "configured": False, "clients": []},
}
SYSTEM = {"hostname": "testfw", "version": "2.2.13-dev", "resolvers": ["1.1.1.1"],
          "management": {"clientInterface": "eth1", "port": 80, "access": ["eth1"]},
          "ssh": {"enabled": True, "port": 22},
          "logging": {"remoteEnabled": False,"server":"","port":514,"localEnabled":True,"serviceRunning":True},
          "memory": {"availableKb": 10, "totalKb": 100}}


class MockHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT), **kw)

    def log_message(self, *args):
        pass

    def do_GET(self):
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
            ("system", ["Alpine system packages", "Check packages", "Apply package updates", "Software updates"]),
            ("module-bind", ["BIND authoritative zones", "Manage records", "Cloudflare"]),
            ("module-dnsmasq", ["DNSMasq DNS engine", "Upstream servers", "DNS resolver (dnsmasq)"]),
            ("module-ddns", ["Dynamic DNS", "Configure Inadyn provider", "Cloudflare DNS (pfSense migration)", "cloud.blaize.net", "home.blaize.net", "Check records"]),
            ("module-openvpn", ["OpenVPN routed server", "OpenVPN clients"]),
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
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
