#!/usr/bin/env python3
"""Manage WireGuard peers without exposing server/client secret material in snapshots."""
import base64
import ipaddress
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

CONF = pathlib.Path(os.environ.get("LFW_MODULE_CONFIG_DIR", "/etc/litefw-addons")) / "wireguard.json"
CLIENTS = CONF.parent / "wg-clients"
CONTROLLER = pathlib.Path(__file__).resolve().parents[1] / "wireguard" / "module.sh"
VALID_NAME = re.compile(r"^[a-zA-Z][a-zA-Z0-9_-]{0,31}$")


def fail(message):
    raise ValueError(message)


def key_valid(key):
    try:
        return len(base64.b64decode(key, validate=True)) == 32
    except Exception:
        return False


def cmd(args, input_data=None):
    return subprocess.check_output(args, input=input_data, stderr=subprocess.PIPE).decode().strip()


def config():
    if not CONF.exists():
        fail("Configure the WireGuard server before adding peers")
    state = json.loads(CONF.read_text())
    if not state.get("interface"):
        fail("WireGuard server interface is missing")
    return state


def authorized_id(value):
    if not isinstance(value, str) or not VALID_NAME.fullmatch(value):
        fail("Peer name: letters, numbers, underscores or hyphens, max 32 characters")
    return value


def validate_cidr(value):
    try:
        network = ipaddress.IPv4Network(value, strict=False)
    except Exception:
        fail("A valid client IPv4 address/prefix is required")
    if network.prefixlen < 16 or network.prefixlen > 32:
        fail("Client tunnel prefix must be /16 through /32")
    return value


def save(state):
    CONF.parent.mkdir(parents=True, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix=".wireguard-", suffix=".json", dir=str(CONF.parent))
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(state, out)
            out.write("\n")
        os.chmod(path, 0o600)
        # Reuse exactly the native WireGuard validation, config and ownership rules.
        cmd([str(CONTROLLER), "configure", path])
    finally:
        if os.path.exists(path):
            os.unlink(path)


def peer_info(state):
    peers = []
    for item in state.get("peers", []):
        peer = {k:v for k,v in item.items() if k not in {"privateKey","presharedKey"}}
        peer["hasClientProfile"] = bool(item.get("id") and (CLIENTS / (str(item["id"]) + ".key")).is_file())
        peers.append(peer)
    result = {"peers":peers}
    key = state.get("privateKey","")
    if key_valid(key):
        result["publicKey"] = cmd(["wg","pubkey"],(key+"\n").encode())
    return result


def main():
    if len(sys.argv) < 2:
        fail("Missing WireGuard operation")
    action = sys.argv[1]
    body = json.loads(pathlib.Path(sys.argv[2]).read_text()) if len(sys.argv)>2 else {}
    if not isinstance(body,dict):
        fail("Invalid peer request")
    state = config()
    peers = state.setdefault("peers", [])
    if action == "list":
        return peer_info(state)
    peer_id = authorized_id(body.get("id", ""))
    existing = next((p for p in peers if p.get("id")==peer_id),None)
    if action == "peerset":
        public = body.get("publicKey","")
        if not public and existing:
            public = existing["publicKey"]
        generated = None
        if not public:
            generated = cmd(["wg","genkey"])
            public = cmd(["wg","pubkey"],(generated+"\n").encode())
        if not key_valid(public):
            fail("Invalid WireGuard public key")
        if any(p.get("publicKey")==public and p.get("id")!=peer_id for p in peers):
            fail("A different peer already uses that public key")
        allowed = validate_cidr(body.get("allowedIPs",""))
        if any(p.get("allowedIPs")==allowed and p.get("id")!=peer_id for p in peers):
            fail("Another peer already uses this tunnel address")
        endpoint = body.get("endpoint","")
        if not isinstance(endpoint,str) or len(endpoint)>253 or not re.fullmatch(r"[A-Za-z0-9.:-]*",endpoint):
            fail("Invalid peer endpoint; expected hostname:port or IPv4:port")
        keepalive = body.get("persistentKeepalive",25)
        if not isinstance(keepalive,int) or not 0<=keepalive<=65535:
            fail("Keepalive must be 0–65535 seconds")
        enabled=body.get("enabled", True)
        if not isinstance(enabled,bool):
            fail("Enabled must be true or false")
        if existing:
            peers.remove(existing)
        peers.append({"id":peer_id,"publicKey":public,"allowedIPs":allowed,
                      "endpoint":endpoint,"persistentKeepalive":keepalive,"enabled":enabled})
        save(state)
        if generated:
            CLIENTS.mkdir(exist_ok=True,mode=0o700)
            path=CLIENTS/(peer_id+".key")
            fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,"w") as out:
                out.write(generated+"\n")
        return {"saved":True,"generatedClientKey":bool(generated),"restartRequired":True}
    if not existing:
        fail("WireGuard peer not found")
    if action == "peerenable":
        enabled=body.get("enabled")
        if not isinstance(enabled,bool):
            fail("Enabled must be true or false")
        existing["enabled"]=enabled
        save(state)
        return {"enabled":enabled,"restartRequired":True}
    if action == "peerremove":
        peers.remove(existing)
        save(state)
        (CLIENTS/(peer_id+".key")).unlink(missing_ok=True)
        return {"removed":True,"restartRequired":True}
    if action == "clientprofile":
        path=CLIENTS/(peer_id+".key")
        if not path.is_file():
            fail("This peer supplied its own public key; LiteFW has no client private key to export")
        server=state.get("serverEndpoint","")
        if not isinstance(server,str) or not re.fullmatch(r"[A-Za-z0-9.-]{3,253}",server):
            fail("Set the server public hostname/IP under WireGuard server settings before exporting")
        server_key=state.get("privateKey","")
        if not key_valid(server_key):
            fail("Server private key is missing")
        public=cmd(["wg","pubkey"],(server_key+"\n").encode())
        routes=state.get("clientRoutes") or str(ipaddress.IPv4Interface(state["address"].split(",")[0]).network)
        try:
            ipaddress.IPv4Network(routes, strict=False)
        except Exception:
            fail("Invalid client route")
        private=path.read_text().strip()
        if not key_valid(private):
            fail("Stored client key is invalid")
        result=["[Interface]","PrivateKey = "+private,"Address = "+existing["allowedIPs"]]
        dns=state.get("dns","")
        if dns:
            try: ipaddress.IPv4Address(dns)
            except Exception: fail("Client DNS must be an IPv4 address")
            result.append("DNS = "+dns)
        result+=["","[Peer]","PublicKey = "+public,
                 "Endpoint = "+server+":"+str(state["listenPort"]),
                 "AllowedIPs = "+routes,"PersistentKeepalive = 25",""]
        return {"filename":peer_id+".conf","profile":"\n".join(result)}
    fail("Unknown WireGuard peer operation")


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except (ValueError,OSError,subprocess.CalledProcessError) as exc:
        print("WireGuard peers: "+str(exc),file=sys.stderr)
        sys.exit(1)
