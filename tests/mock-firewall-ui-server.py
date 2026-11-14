#!/usr/bin/env python3
"""Local-only mock API for rendering the LiteFW firewall UI in a test browser."""
import http.server
import json
import os
import urllib.parse

WAN = "wan0"
LAN = "lan0"

def rule(uid, chain, action, source, destination, proto, ports, label):
    in_if = WAN if source["scope"] == "wan" else LAN if source["scope"] == "interface" else ""
    out_if = WAN if destination["scope"] == "wan" else LAN if destination["scope"] == "interface" else ""
    return {
        "id": uid, "chain": chain, "action": action,
        "source": source, "destination": destination,
        "in": in_if, "out": out_if,
        "src": source.get("address", ""), "dst": destination.get("address", ""),
        "srcPorts": source.get("ports", ""), "ports": ports,
        "proto": proto, "description": label, "managed": True, "raw": ""
    }

any_port = {"scope":"wan","interface":"","address":"","ports":""}
host = {"scope":"host","interface":"","address":"","ports":""}
office = {"scope":"interface","interface":"lan0","address":"","ports":"1024-65535"}
fw = {
    "policies":{"INPUT":"DROP","FORWARD":"DROP","OUTPUT":"ACCEPT"},
    "rules":[
        rule("11111111","forward","accept",office,
             {"scope":"wan","interface":"","address":"","ports":"443"},"tcp","443","Office web access"),
        rule("22222222","input","drop",any_port,host,"icmp","","Block WAN ping"),
        rule("33333333","output","drop",host,
             {"scope":"wan","interface":"","address":"","ports":"53"},"udp","53","Block host DNS")
    ],
    "forwards":[],
    "masquerade":["wan0"]
}
interfaces = [
    {"name":LAN,"label":"Office","role":"lan","kind":"physical","master":"",
     "addresses":["192.168.10.1/24"],"carrier":True},
    {"name":WAN,"label":"WAN","role":"wan","kind":"physical","master":"",
     "addresses":["198.51.100.10/24"],"carrier":True}
]
data = {
    "/api/identity":{"hostname":"litefw-ui-test","version":"test"},
    "/api/firewall":{"firewall":{k:v for k,v in fw.items() if k != "forwards"}},
    "/api/port-forwards":{"firewall":{"forwards":[]}},
    "/api/segments":{"interfaces":interfaces},
    "/api/dhcp":{"dhcp":{"leases":[],"reservations":[]}},
    "/api/system":{"system":{"hostname":"litefw-ui-test","version":"test",
        "management":{"port":80,"access":["any"],"clientInterface":"lan0"},
        "ssh":{"enabled":False,"port":22}}}
}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,directory="/src/www",**kwargs)

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path in data:
            payload = json.dumps(data[path]).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Cache-Control","no-store")
            self.send_header("Content-Length",str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        super().do_GET()

    def log_message(self,*args):
        pass

if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1",8097),Handler).serve_forever()