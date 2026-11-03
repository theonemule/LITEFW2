#!/usr/bin/env python3
"""Render API, UI and CLI manuals from the tracked OpenAPI and Markdown sources."""
from pathlib import Path
import html
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CHECK = "--check" in sys.argv
SPEC = json.loads((ROOT / "docs/openapi.json").read_text())
VERSION = (ROOT / "VERSION").read_text().strip()
if SPEC["openapi"] != "3.1.0" or SPEC["info"]["version"] != VERSION:
    sys.exit("OpenAPI version must match VERSION")
routes = [(method.upper(), path, info)
          for path, methods in SPEC["paths"].items()
          for method, info in methods.items()]
assert len(routes) >= 100 and len({(method, path) for method, path, _ in routes}) == len(routes)
cgi = (ROOT / "cgi/api.cgi").read_text()
modules = (ROOT / "lib/modules.sh").read_text()
for method, path, _ in routes:
    if path.startswith("/modules/") and path.count("/") >= 3 and "{" not in path:
        _, _, module, action = path.split("/")
        if f"op_{module}_{action}()" not in modules:
            sys.exit(f"Unimplemented module operation: {module}.{action}")
    elif method == "GET" and "{" not in path and f"GET:{path}" not in cgi:
        sys.exit(f"Unimplemented GET route: {path}")
    elif method == "POST" and path.startswith("/modules/") and "{" in path:
        pass
    elif method == "POST" and "{" not in path and f"POST:{path}" not in cgi:
        parent=path.rsplit("/",1)[0]
        if f"POST:{parent}/*" not in cgi:
            sys.exit(f"Unimplemented POST route: {path}")

def write(rel, data):
    path = ROOT / rel
    if CHECK:
        if not path.is_file() or path.read_text() != data:
            sys.exit(f"Generated documentation is stale: {rel}; run tools/render-api-docs.py")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

style = """body{margin:0;background:#f7f9fc;color:#1f2937;font:15px/1.55 system-ui,-apple-system,sans-serif}
header{background:#15253b;color:#fff;padding:18px 25px}
header a{color:#cbe3ff;margin-right:18px;text-decoration:none}
main{max-width:1120px;margin:30px auto;padding:0 25px 50px}
h1,h2,h3{color:#132a44}h1{font-size:30px}h2{margin-top:28px}
table{border-collapse:collapse;width:100%;background:#fff;font-size:13px}
td,th{border:1px solid #d7e0eb;padding:8px 11px;text-align:left;vertical-align:top}
th{background:#eaf1f8}
tr:nth-child(even){background:#f7fafc}
code,pre{font-family:ui-monospace,Consolas,monospace}
code{background:#edf2f7;padding:1px 4px}
pre{background:#15253b;color:#f0f6ff;padding:14px;border-radius:6px;overflow-x:auto}
a{color:#1758a5}
aside{background:#fff1cc;padding:15px;border-left:4px solid #edb944}
nav a{display:inline-block;margin:4px 12px 4px 0}
footer{color:#6b7280;padding:20px;text-align:center;font-size:12px}
"""
write("www/docs/manual.css", style)
def inline(text):
    s = html.escape(text)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
               lambda m: f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    return s

def render_markdown(markdown):
    lines=markdown.splitlines()
    out=[]
    state=None
    def close():
        nonlocal state
        if state: out.append({"ul":"</ul>","ol":"</ol>","pre":"</pre>"}[state]); state=None
    for line in lines:
        if not line.strip(): close(); continue
        if line.startswith("    "):
            if state!="pre": close();out.append("<pre>");state="pre"
            out.append(html.escape(line[4:])+"\n")
        elif line.startswith("- "):
            if state!="ul": close();out.append("<ul>");state="ul"
            out.append("<li>"+inline(line[2:])+"</li>")
        elif re.match(r"^[0-9]+\. ",line):
            if state!="ol": close();out.append("<ol>");state="ol"
            out.append("<li>"+inline(re.sub(r"^[0-9]+\. ","",line))+"</li>")
        elif line.startswith("#"):
            close()
            n=min(4,len(line)-len(line.lstrip("#")))
            out.append(f"<h{n}>"+inline(line[n:].strip())+f"</h{n}>")
        else:
            close()
            out.append("<p>"+inline(line)+"</p>")
    close()
    return "\n".join(out)

def page(title,contents):
    return ("""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-Content-Type-Options" content="nosniff">
<link rel="stylesheet" href="/docs/manual.css"><title>"""+html.escape(title)+""" — LiteFW</title></head>
<body><header><strong>LiteFW Manual</strong><nav>
<a href="/docs/index.html">Documentation home</a>
<a href="/docs/ui.html">Web UI</a>
<a href="/docs/api.html">HTTP API</a>
<a href="/docs/cli.html">CLI</a>
<a href="/docs/openapi.json">OpenAPI JSON</a>
<a href="/">Back to LiteFW</a>
</nav></header><main>"""+contents+
"""</main><footer>LiteFW """+html.escape(VERSION)+
""" · Documentation is included with the appliance</footer></body></html>
""")
write("www/docs/ui.html",page("Administrator UI",render_markdown((ROOT/"docs/UI_MANUAL.md").read_text())))
write("www/docs/cli.html",page("Command-line interface",render_markdown((ROOT/"docs/CLI_MANUAL.md").read_text())))
index=("<h1>LiteFW Documentation</h1>"
       "<p>The manuals ship with the appliance and are maintained alongside the source code.</p>"
       '<ul><li><a href="ui.html">Web administration manual</a></li>'
       '<li><a href="api.html">Complete HTTP API endpoint reference</a></li>'
       '<li><a href="cli.html">Standalone CLI manual</a></li>'
       '<li><a href="openapi.json">OpenAPI 3.1 machine-readable specification</a></li></ul>'
       '<aside>Protect authentication credentials: use HTTPS or an encrypted VPN when calling the API.</aside>')
write("www/docs/index.html",page("Documentation",index))
write("www/docs/openapi.json",(ROOT/"docs/openapi.json").read_text())

md=['# LiteFW HTTP API Reference','',f'OpenAPI 3.1 · Version {VERSION}', '',
    'Base URL: /api. Authentication: HTTP Basic or X-API-Key.',
    'All POST mutations require X-LiteFWM: 1 and JSON, except the binary upgrade upload.',
    'API keys have read or admin scope; sensitive key/password/management operations require Basic.', '',
    '| Method | Endpoint | Description |','| --- | --- | --- |']
for method,path,info in routes:
    md.append(f'| {method} | /api{path} | {info["summary"]} |')
md+=['','The canonical source is docs/openapi.json.']
write("docs/API.md","\n".join(md)+"\n")
heads="<h1>LiteFW HTTP API Reference</h1>"
heads+=f'<p>OpenAPI 3.1 · Version {html.escape(VERSION)} · Base URL: <code>/api</code></p>'
heads+='<aside>Basic Auth or X-API-Key. Use encrypted transport. Mutations are POST requests with X-LiteFWM: 1; key administration requires Basic.</aside>'
heads+='<p>Download <a href="openapi.json">OpenAPI JSON</a> for schema validation or SDK generation.</p>'
heads+='<table><thead><tr><th>Verb</th><th>Endpoint</th><th>Purpose</th></tr></thead><tbody>'
for method,path,info in routes:
    heads+='<tr><td>'+html.escape(method)+'</td><td><code>/api'+html.escape(path)+'</code></td><td>'+html.escape(info["summary"])+'</td></tr>'
heads+='</tbody></table>'
write("www/docs/api.html",page("HTTP API reference",heads))

raw_cli=(ROOT/"docs/CLI_MANUAL.md").read_text()
raw_cli=re.sub(r"\[([^\]]+)\]\([^)]+\)",r"\1",raw_cli)
raw_cli=raw_cli.replace("**","").replace("# ","").replace("## ","")
catalog="\n".join(f"{method:<5} /api{path}  - {info['summary']}"
                  for method,path,info in routes)
help_block=("# GENERATED_HELP_START\n"
            "print_version(){ printf 'LiteFW standalone CLI %s\\n' '"+VERSION+"' ; }\n"
            "print_help(){ cat <<'LITEFW_EMBEDDED_MANUAL'\n"+raw_cli.strip()+
            "\nLITEFW_EMBEDDED_MANUAL\n}\n"
            "print_api_catalog(){ cat <<'LITEFW_EMBEDDED_ENDPOINTS'\n"+
            catalog+"\nLITEFW_EMBEDDED_ENDPOINTS\n}\n"
            "# GENERATED_HELP_END")
cli=(ROOT/"bin/litefw").read_text()
start=cli.index("# GENERATED_HELP_START")
end=cli.index("# GENERATED_HELP_END",start)+len("# GENERATED_HELP_END")
write("bin/litefw",cli[:start]+help_block+cli[end:])
print(f"Rendered {len(routes)} API operations, 3 manual pages, CLI embedded help")
