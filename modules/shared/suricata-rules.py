#!/usr/bin/env python3
"""LiteFW Suricata ruleset manager; imports, sources, toggles and validation."""
import ipaddress
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

BASE = pathlib.Path(os.environ.get("LFW_SURICATA_RULES_DIR", "/etc/litefw-addons/suricata"))
CONF = pathlib.Path(os.environ.get("LFW_SURICATA_CONF", "/etc/suricata/suricata.yaml"))
ID = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")
SID = re.compile(r"\bsid\s*:\s*([1-9][0-9]{0,9})\s*;")
MSG = re.compile(r'\bmsg\s*:\s*"([^"]{0,250})"')
MAX_BYTES = 2_097_152


def error(message):
    raise ValueError(message)


def load_catalog(root):
    f = root / "catalog.json"
    if f.exists():
        data = json.loads(f.read_text())
        if isinstance(data.get("sources"), list) and isinstance(data.get("disabledSids"), list):
            return data
        error("Invalid stored Suricata catalog")
    return {"sources": [], "disabledSids": []}


def check_id(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        error("Ruleset ID must be lowercase letters, numbers, hyphen or underscore (max 40)")
    return value


def parse_rules(text):
    if not isinstance(text, str) or len(text.encode("utf-8")) > MAX_BYTES:
        error("Plain-text ruleset exceeds 2 MiB")
    if "\0" in text:
        error("Binary Suricata ruleset not allowed")
    rows = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = SID.search(line)
        if not m:
            error("Every non-comment rule must contain a valid SID")
        action = line.split(None, 1)[0]
        if action not in {"alert", "drop", "reject", "pass"}:
            error("Invalid Suricata rule action: " + action)
        label = MSG.search(line)
        rows.append({"sid": m.group(1), "message": label.group(1) if label else "",
                     "action": action, "text": line})
    if not rows:
        error("No Suricata signatures found")
    return rows


def secure_download(url):
    value = urllib.parse.urlparse(url)
    if (value.scheme != "https" or not value.hostname or value.port not in (None, 443)
            or value.username or value.password or value.fragment or len(url) > 512):
        error("A public HTTPS source URL is required")
    hostname = value.hostname
    if "." not in hostname or hostname.endswith(".local"):
        error("A publicly resolvable source hostname is required")
    try:
        addresses = socket.getaddrinfo(hostname, 443, family=socket.AF_INET,
                                        type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        error("Unable to resolve rule source: " + str(exc))
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        error("Rule source resolves to an internal/reserved IP address")
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, msg, headers, new_url):
            error("Redirecting Suricata rule sources is not permitted")
    opener = urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(url, headers={"User-Agent": "LiteFW-Suricata/1.0"})
    with opener.open(request, timeout=25) as stream:
        payload = stream.read(MAX_BYTES + 1)
    if len(payload) > MAX_BYTES:
        error("Downloaded ruleset exceeds 2 MiB")
    text = payload.decode("utf-8")
    parse_rules(text)
    return text


def write_secure(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".litefw-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def compose(root, catalog):
    disabled = {str(x) for x in catalog["disabledSids"]}
    lines, all_rules = [], []
    seen = set()
    for src in catalog["sources"]:
        source_id = check_id(src["id"])
        rule_file = root / "sources" / (source_id + ".rules")
        if not rule_file.exists():
            continue
        for rule in parse_rules(rule_file.read_text(encoding="utf-8")):
            entry = dict(rule, source=source_id,
                         enabled=bool(src["enabled"] and rule["sid"] not in disabled))
            all_rules.append({k: v for k, v in entry.items() if k != "text"})
            if not entry["enabled"]:
                continue
            if rule["sid"] in seen:
                error("Duplicate enabled SID " + rule["sid"] + " across rulesets")
            seen.add(rule["sid"])
            lines.append(rule["text"])
    return ("\n".join(lines) + ("\n" if lines else "")), all_rules


def validate_suricata(text, path):
    if not text.strip():
        return
    write_secure(path, text, 0o640)
    completed = subprocess.run(["suricata", "-T", "-c", str(CONF), "-S", str(path)],
                               text=True, capture_output=True, timeout=75)
    if completed.returncode:
        error("Suricata rejected candidate rules: " + (completed.stderr + completed.stdout)[-1200:])


def main():
    if len(sys.argv) < 2:
        error("Operation required")
    operation = sys.argv[1]
    body = json.loads(pathlib.Path(sys.argv[2]).read_text()) if len(sys.argv) > 2 else {}
    if not isinstance(body, dict):
        error("Request must be a JSON object")
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(BASE, 0o700)
    (BASE / "sources").mkdir(mode=0o700, exist_ok=True)
    current = load_catalog(BASE)
    if operation == "list":
        active, rules = compose(BASE, current)
        return {"sources": current["sources"], "disabledSids": current["disabledSids"],
                "rules": rules[:400], "totalRules": len(rules), "activeRules":sum(r["enabled"] for r in rules)}
    if operation == "rulesexport":
        name = body.get("id", "")
        file = BASE / "active.rules" if not name else BASE / "sources" / (check_id(name) + ".rules")
        if not file.exists():
            error("No downloaded ruleset yet")
        return {"filename": (name or "active") + ".rules", "content": file.read_text()}
    with tempfile.TemporaryDirectory(prefix="suricata-stage-") as working:
        root = pathlib.Path(working)
        shutil.copytree(BASE / "sources", root / "sources", dirs_exist_ok=True)
        catalog = json.loads(json.dumps(current))
        sources = catalog["sources"]
        source_id = body.get("id", "")
        if operation in {"sourceset", "sourceenable", "sourceremove", "sourcerefresh", "rulesupload"}:
            check_id(source_id)
        if operation == "sourceset":
            name = body.get("name", "")
            url = body.get("url", "")
            if not isinstance(name, str) or not 1 <= len(name) <= 80:
                error("Source display name must be 1-80 characters")
            # Verify URL without making an HTTP request on save.
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                error("Source must use a public HTTPS URL without credentials")
            sources[:] = [s for s in sources if s["id"] != source_id]
            sources.append({"id":source_id, "name":name, "url":url,
                            "enabled":bool(body.get("enabled", True)), "kind":"url"})
        elif operation == "rulesupload":
            name = body.get("name", "")
            if not isinstance(name, str) or not 1 <= len(name) <= 80:
                error("Uploaded source display name required")
            text = body.get("content", "")
            parse_rules(text)
            (root / "sources" / (source_id + ".rules")).write_text(text)
            sources[:] = [s for s in sources if s["id"] != source_id]
            sources.append({"id": source_id,"name":name,"url":"","enabled":True,"kind":"upload"})
        elif operation in {"sourceenable","sourcerefresh","sourceremove"}:
            match = next((s for s in sources if s["id"] == source_id), None)
            if not match:
                error("Unknown rule source")
            if operation == "sourceenable":
                if not isinstance(body.get("enabled"), bool):
                    error("Enabled must be true or false")
                match["enabled"] = body["enabled"]
            elif operation == "sourcerefresh":
                if match["kind"] != "url":
                    error("Only HTTPS rule sources can be refreshed")
                (root / "sources" / (source_id + ".rules")).write_text(secure_download(match["url"]))
            else:
                sources.remove(match)
                (root / "sources" / (source_id + ".rules")).unlink(missing_ok=True)
        elif operation == "ruleenable":
            sid = str(body.get("sid", ""))
            if not SID.fullmatch("sid:"+sid+";"):
                error("Invalid SID")
            if not isinstance(body.get("enabled"), bool):
                error("Enabled must be a boolean")
            disabled = {str(x) for x in catalog["disabledSids"]}
            if body["enabled"]:
                disabled.discard(sid)
            else:
                disabled.add(sid)
            catalog["disabledSids"] = sorted(disabled)
        elif operation in {"rulesupdate", "rebuild"}:
            if operation == "rulesupdate":
                for src in sources:
                    if src["kind"] == "url" and src["enabled"]:
                        (root / "sources" / (check_id(src["id"]) + ".rules")).write_text(secure_download(src["url"]))
        else:
            error("Unknown Suricata rules operation")
        if len(sources) > 30 or len(catalog["disabledSids"]) > 10000:
            error("Ruleset or SID exclusion limit exceeded")
        active, rules = compose(root, catalog)
        validate_suricata(active, root / "active.rules")
        # All validation is complete. Publish files only after every check passes.
        for file in (root / "sources").glob("*.rules"):
            write_secure(BASE / "sources" / file.name, file.read_text(), 0o640)
        valid_names = {s["id"] + ".rules" for s in sources}
        for file in (BASE / "sources").glob("*.rules"):
            if file.name not in valid_names:
                file.unlink()
        write_secure(BASE / "active.rules", active, 0o640)
        write_secure(BASE / "catalog.json", json.dumps(catalog, indent=2) + "\n")
        return {"saved":True, "totalRules":len(rules),
                "activeRules":sum(r["enabled"] for r in rules), "restartRequired":True}


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("Suricata rules: " + str(exc), file=sys.stderr)
        sys.exit(1)
