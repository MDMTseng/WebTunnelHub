#!/usr/bin/env python3
"""Local HTTP server for hub-tunnel: `/` lists local URLs + Hub tunnels (per-app Close → hub-unregister); `/status` runs hub-status.sh; `/readme` and `/quickuse` render Markdown via marked.js (CDN)."""
from __future__ import annotations
import html
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Callable
from urllib.parse import urlparse

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
TITLE = os.environ.get("HELLO_TITLE", "WebTunnelHub")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
HUB_STATUS_SH = os.path.join(REPO_ROOT, "hub-status.sh")
HUB_UNREGISTER_SH = os.path.join(REPO_ROOT, "hub-unregister.sh")
# Default app when POST /close-tunnel has no JSON body (e.g. example/start.sh uses hub-serve).
HUB_CLOSE_APP = (os.environ.get("HUB_CLOSE_APP") or "hub-serve").strip() or "hub-serve"
README_MD = os.path.join(REPO_ROOT, "README.md")
QUICKUSE_MD = os.path.join(REPO_ROOT, "QuickUse.md")
# Browser-side Markdown (no project dep); pinned major version on jsDelivr.
_MARKED_CDN = "https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"
HUB_STATUS_TIMEOUT = int(os.environ.get("HUB_STATUS_TIMEOUT", "120"))
HUB_BASH = os.environ.get("HUB_BASH", "bash")
STATUS_REFRESH = os.environ.get("HUB_STATUS_REFRESH_SEC", "").strip()

_HUB_STATUS_ROUTES_MARKER = "=== EC2 Caddy registered subdomain routes"
_HUB_APP_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$")


def _valid_hub_app_name(name: str) -> bool:
    """Same rule as hub_validate_app_name in hub-common.sh."""
    return bool(name and _HUB_APP_NAME_RE.fullmatch(name))


def _parse_hub_status_routes(text: str) -> tuple[list[tuple[str, str]], str | None]:
    """Parse app name and registration note from hub-status.sh routes section.

    Lines look like: ``hub-serve -> reverse_proxy 127.0.0.1:25234  # note…``
    """
    pos = text.find(_HUB_STATUS_ROUTES_MARKER)
    if pos == -1:
        return [], "hub-status output missing Caddy routes section."

    rest = text[pos + len(_HUB_STATUS_ROUTES_MARKER) :]
    nl = rest.find("\n")
    if nl == -1:
        return [], "Malformed hub-status output."
    body_lines: list[str] = []
    for raw in rest[nl + 1 :].splitlines():
        line = raw.rstrip("\r")
        s = line.strip()
        if not s:
            break
        if s.startswith("===") or s.startswith("Legend:"):
            break
        body_lines.append(line)

    if not body_lines:
        if "(Could not connect or remote command failed" in text:
            return [], "Could not load Hub routes (SSH failed; open /status for full hub-status)."
        return [], None

    if len(body_lines) == 1 and "(No route entries.)" in body_lines[0]:
        return [], None

    rows: list[tuple[str, str]] = []
    sep = " -> "
    note_sep = "  # "
    for line in body_lines:
        if sep not in line:
            continue
        name, tail = line.split(sep, 1)
        name = name.strip()
        if not name or name.startswith("("):
            continue
        tail = tail.strip()
        note = ""
        if note_sep in tail:
            _proxy, _, note = tail.partition(note_sep)
            note = note.strip()
        rows.append((name, note))
    return rows, None


def _parse_dotenv(path: str) -> dict:
    out: dict[str, str] = {}
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            out[key] = val
    return out


def _merged_config_env() -> dict[str, str]:
    dot = _parse_dotenv(os.path.join(REPO_ROOT, ".env"))
    return {**dot, **dict(os.environ)}


def _parse_hub_public_url(url: str) -> tuple[str, str, str] | None:
    if not url:
        return None
    u = urlparse(url.strip())
    if not u.scheme or not u.hostname:
        return None
    scheme = u.scheme.lower()
    host = u.hostname
    port = u.port
    if port is None:
        port = 443 if scheme == "https" else 80
    return scheme, host, str(port)


def _hub_app_public_url(scheme: str, host: str, port: str, app: str) -> str:
    return "%s://%s.%s:%s/" % (scheme, app, host, port)


def _fetch_registered_tunnels() -> tuple[list[tuple[str, str, str]], str | None]:
    """Return ( [(app_name, registration_note, public_url), ...], error_message_or_none ).

    Names and notes come from ``hub-status.sh`` (same Caddy route lines as /status).
    """
    env = _merged_config_env()
    pub = (env.get("HUB_PUBLIC_URL") or "").strip()
    parsed = _parse_hub_public_url(pub)
    if not parsed:
        return [], "HUB_PUBLIC_URL is missing or not a valid URL with host (see .env)."

    scheme, hub_host, hub_port = parsed

    if not os.path.isfile(HUB_STATUS_SH):
        return [], "hub-status.sh not found in repository root (%s)." % REPO_ROOT

    try:
        proc = subprocess.run(
            [HUB_BASH, HUB_STATUS_SH],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=HUB_STATUS_TIMEOUT,
            env={**os.environ},
        )
    except FileNotFoundError:
        return [], (
            "Could not run %r (install Git Bash on Windows or set HUB_BASH to bash)."
            % HUB_BASH
        )
    except subprocess.TimeoutExpired:
        return [], "hub-status.sh timed out after %s seconds." % HUB_STATUS_TIMEOUT

    text = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        return [], "hub-status.sh exited with code %s. %s" % (
            proc.returncode,
            text.strip()[:500],
        )

    parsed_rows, perr = _parse_hub_status_routes(text)
    if perr:
        return [], perr

    out_rows: list[tuple[str, str, str]] = []
    for name, note in parsed_rows:
        url = _hub_app_public_url(scheme, hub_host, hub_port, name)
        out_rows.append((name, note, url))
    return out_rows, None


def _run_close_tunnel(app: str) -> tuple[bool, str]:
    """Run hub-unregister.sh for ``app``; tears down SSH tunnel when demo used hub-tunnel.sh."""
    if not _valid_hub_app_name(app):
        return False, "Invalid app name (use letters, digits, _-; max 48 chars)."
    if not os.path.isfile(HUB_UNREGISTER_SH):
        return False, "hub-unregister.sh not found in repository root (%s)." % REPO_ROOT
    try:
        proc = subprocess.run(
            [HUB_BASH, HUB_UNREGISTER_SH, app],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=HUB_STATUS_TIMEOUT,
            env={**os.environ},
        )
    except FileNotFoundError:
        return False, (
            "Could not run %r (install Git Bash on Windows or set HUB_BASH to bash)." % HUB_BASH
        )
    except subprocess.TimeoutExpired:
        return False, "hub-unregister.sh timed out after %s seconds." % HUB_STATUS_TIMEOUT
    text = ((proc.stdout or "") + (proc.stderr or "")).strip()
    if proc.returncode != 0:
        err = text[:4000] if text else "hub-unregister.sh exited with code %s." % proc.returncode
        return False, err
    return True, text[:4000] if text else "Tunnel closed."


def _run_hub_status():
    if not os.path.isfile(HUB_STATUS_SH):
        return 127, "hub-status.sh not found in repository root (%s)" % REPO_ROOT
    try:
        proc = subprocess.run(
            [HUB_BASH, HUB_STATUS_SH],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=HUB_STATUS_TIMEOUT,
            env={**os.environ},
        )
    except FileNotFoundError:
        return 127, (
            "Could not run %r (install Git Bash on Windows or set HUB_BASH to bash)." % HUB_BASH
        )
    except subprocess.TimeoutExpired:
        return 124, "hub-status.sh timed out after %s seconds." % HUB_STATUS_TIMEOUT
    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, out


def _page_status() -> bytes:
    code, text = _run_hub_status()
    esc = html.escape(text, quote=False)
    banner = ""
    if code != 0:
        banner = (
            '<p style="color:#b00;font-weight:bold">hub-status.sh exited with code %s</p>' % code
        )
    refresh_meta = ""
    if STATUS_REFRESH.isdigit() and int(STATUS_REFRESH) > 0:
        refresh_meta = (
            '<meta http-equiv="refresh" content="%s">' % int(STATUS_REFRESH)
        )
    body = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        + refresh_meta
        + "<title>"
        + html.escape(TITLE)
        + " — Hub status</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:1rem}"
        "pre{white-space:pre-wrap;background:#f4f4f4;padding:1rem;overflow:auto}"
        "a{color:#06c}</style></head><body>"
        "<h1>"
        + html.escape(TITLE)
        + "</h1>"
        '<p><a href="/">Home</a> · <a href="/readme">README</a> · '
        '<a href="/quickuse">Quick use</a> · '
        "Hub status (from <code>hub-status.sh</code>)</p>"
        + banner
        + "<pre>"
        + esc
        + "</pre></body></html>"
    )
    return body.encode("utf-8")


def _urls_html_list() -> str:
    lines = []
    for urlpath, desc, _fn in ROUTES:
        lines.append(
            "<li><a href=\"%s\"><code>%s</code></a> — %s</li>"
            % (html.escape(urlpath), html.escape(urlpath), html.escape(desc))
        )
    return "<ul>" + "".join(lines) + "</ul>"


def _hub_tunnel_list_html() -> str:
    """HTML block: registered Hub apps with public URL links and registration notes."""
    rows, err = _fetch_registered_tunnels()

    parts = [
        '<h2 style="margin-top:1.5rem;font-size:1.15rem;font-weight:600">'
        "Hub tunnels (public)</h2>"
        '<p style="color:#666;font-size:0.95rem;margin:0.25rem 0 0.5rem">'
        "Names and registration notes match the "
        "<code>EC2 Caddy registered subdomain routes</code> section of "
        "<code>hub-status.sh</code> (same data as <a href=\"/status\">/status</a>). "
        "Each row has <strong>Close</strong> to run <code>hub-unregister.sh</code> for that app "
        "(with a confirmation prompt).</p>"
    ]

    if err:
        parts.append('<p style="color:#666">%s</p>' % html.escape(err))
        return "".join(parts)

    if not rows:
        parts.append(
            "<p style=\"color:#666\">No registered apps on EC2 "
            "(<code>hub-routes/*.caddy</code>) yet.</p>"
        )
        return "".join(parts)

    btn_style = (
        "background:#c62828;color:#fff;border:none;padding:0.2rem 0.55rem;"
        "border-radius:5px;font-size:0.8rem;font-weight:600;cursor:pointer;"
        "vertical-align:middle;flex-shrink:0"
    )
    items = []
    for name, note, url in rows:
        esc_u = html.escape(url)
        esc_n = html.escape(name)
        esc_attr = html.escape(name, quote=True)
        item = (
            '<li style="display:flex;flex-wrap:wrap;align-items:baseline;gap:0.4rem 0.75rem;'
            'margin:0.35rem 0">'
            "<span>"
            "<a href=\"%s\" rel=\"noopener noreferrer\"><code>%s</code></a> — "
            "<strong>%s</strong>" % (esc_u, esc_u, esc_n)
        )
        n = note.strip()
        if n:
            item += ": %s" % html.escape(n)
        item += (
            "</span>"
            '<button type="button" class="hub-close-app-btn" data-app="%s" style="%s">'
            "Close</button>"
            '<span class="hub-close-app-msg" aria-live="polite" style="font-size:0.85rem;color:#666"></span>'
            "</li>"
            % (esc_attr, btn_style)
        )
        items.append(item)
    parts.append(
        '<ul id="hub-tunnels-list" style="margin:0.5rem 0 0 1.25rem;padding:0">'
        + "".join(items)
        + "</ul>"
    )
    parts.append(
        '<script>(function(){document.body.addEventListener("click",function(ev){'
        'var t=ev.target;if(!t||!t.classList||!t.classList.contains("hub-close-app-btn"))return;'
        'var app=t.getAttribute("data-app");if(!app)return;'
        "if(!window.confirm('Close tunnel for \"'+app+'\"?\\n\\n"
        "This removes the Hub route on EC2 and stops the SSH tunnel for that app.'))return;"
        'var li=t.closest("li"),msg=li&&li.querySelector(".hub-close-app-msg");'
        'if(msg)msg.textContent="Closing…";t.disabled=true;'
        'fetch("/close-tunnel",{method:"POST",headers:{"Content-Type":"application/json"},'
        'body:JSON.stringify({app:app})}).then(function(r){'
        'return r.json().then(function(j){return{r:r,j:j};});}).then(function(x){'
        "if(x.j&&x.j.ok){if(msg){msg.textContent=x.j.message||\"Done.\";msg.style.color=\"#2e7d32\";}"
        "setTimeout(function(){if(li&&li.parentNode)li.parentNode.removeChild(li);},800);"
        "}else{var err=(x.j&&x.j.error)||x.r.statusText||\"Error\";"
        'if(msg)msg.textContent="";alert(err);t.disabled=false;}'
        '}).catch(function(e){if(msg)msg.textContent="";alert(String(e));t.disabled=false;});'
        "});})();</script>"
    )
    return "".join(parts)


def _page_home() -> bytes:
    body = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>"
        + html.escape(TITLE)
        + "</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:1rem}"
        "a{color:#06c}ul{margin:0.5rem 0 0 1.25rem;padding:0}</style>"
        "</head><body><h1>"
        + html.escape(TITLE)
        + "</h1>"
        "<p>Local server is up. This page:</p>"
        + _urls_html_list()
        + _hub_tunnel_list_html()
        + "</body></html>"
    )
    return body.encode("utf-8")


def _readme_md_raw() -> bytes:
    if not os.path.isfile(README_MD):
        return (
            "# README.md not found\n\n"
            "Add **README.md** at the repository root.\n"
        ).encode("utf-8")
    with open(README_MD, encoding="utf-8", errors="replace") as f:
        return f.read().encode("utf-8")


def _quickuse_md_raw() -> bytes:
    if not os.path.isfile(QUICKUSE_MD):
        return (
            "# QuickUse.md not found\n\n"
            "Add **QuickUse.md** at the repository root.\n"
        ).encode("utf-8")
    with open(QUICKUSE_MD, encoding="utf-8", errors="replace") as f:
        return f.read().encode("utf-8")


def _page_readme() -> bytes:
    esc_cdn = html.escape(_MARKED_CDN, quote=True)
    body = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>"
        + html.escape(TITLE)
        + " — README</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:1rem;max-width:50rem;line-height:1.5}"
        "a{color:#06c}code,pre{background:#f4f4f4;padding:0.15em 0.35em;border-radius:3px;font-size:0.95em}"
        "pre{padding:1rem;overflow:auto}table{border-collapse:collapse;width:100%}"
        "th,td{border:1px solid #ccc;padding:0.4rem 0.6rem}</style></head><body>"
        '<p><a href="/">Home</a> · <a href="/quickuse">Quick use</a> · '
        '<a href="/status">Status</a></p>'
        "<h1>README</h1>"
        '<p style="color:#666">From <code>README.md</code> (loaded as <a href="/readme.md"><code>/readme.md</code></a>).</p>'
        '<div id="rc"><p>Loading…</p></div>'
        '<script src="'
        + esc_cdn
        + '"></script><script>'
        "fetch('/readme.md').then(function(r){"
        "if(!r.ok)throw new Error('HTTP '+r.status);return r.text();"
        "}).then(function(t){"
        "document.getElementById('rc').innerHTML=marked.parse(t);"
        "}).catch(function(e){"
        "document.getElementById('rc').innerHTML="
        "'<p style=\"color:#b00\">Could not load README.md: '+String(e)+'</p>';"
        "});</script></body></html>"
    )
    return body.encode("utf-8")


def _page_quickuse() -> bytes:
    esc_cdn = html.escape(_MARKED_CDN, quote=True)
    body = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>"
        + html.escape(TITLE)
        + " — Quick use</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:1rem;max-width:50rem;line-height:1.5}"
        "a{color:#06c}code,pre{background:#f4f4f4;padding:0.15em 0.35em;border-radius:3px;font-size:0.95em}"
        "pre{padding:1rem;overflow:auto}table{border-collapse:collapse;width:100%}"
        "th,td{border:1px solid #ccc;padding:0.4rem 0.6rem}</style></head><body>"
        '<p><a href="/">Home</a> · <a href="/readme">README</a> · '
        '<a href="/status">Status</a></p>'
        "<h1>Quick use guide</h1>"
        '<p style="color:#666">From <code>QuickUse.md</code> in this repo (loaded as <a href="/quickuse.md"><code>/quickuse.md</code></a>).</p>'
        '<div id="qc"><p>Loading…</p></div>'
        '<script src="'
        + esc_cdn
        + '"></script><script>'
        "fetch('/quickuse.md').then(function(r){"
        "if(!r.ok)throw new Error('HTTP '+r.status);return r.text();"
        "}).then(function(t){"
        "document.getElementById('qc').innerHTML=marked.parse(t);"
        "}).catch(function(e){"
        "document.getElementById('qc').innerHTML="
        "'<p style=\"color:#b00\">Could not load QuickUse.md: '+String(e)+'</p>';"
        "});</script></body></html>"
    )
    return body.encode("utf-8")


# (path, short description, handler). Single source of truth for GET routes.
ROUTES: list[tuple[str, str, Callable[[], bytes]]] = [
    ("/", "Home — health check and this list", _page_home),
    ("/status", "Hub status via hub-status.sh (SSH to EC2; may take a few seconds)", _page_status),
    (
        "/readme",
        "README.md (project overview, rendered in the browser)",
        _page_readme,
    ),
    (
        "/quickuse",
        "Quick use guide (QuickUse.md, rendered in the browser)",
        _page_quickuse,
    ),
]

GET_HANDLERS = {path: fn for path, _desc, fn in ROUTES}


def _wfile_write_ignore_disconnect(wfile, data: bytes) -> None:
    """Client may close early (tunnel/browser); Windows raises ConnectionAbortedError (WinError 10053)."""
    try:
        wfile.write(data)
    except ConnectionError:
        pass


def _read_post_json(handler: BaseHTTPRequestHandler) -> dict:
    try:
        n = int(handler.headers.get("Content-Length", "0") or 0)
    except ValueError:
        n = 0
    if n <= 0:
        return {}
    raw = handler.rfile.read(n)
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return obj if isinstance(obj, dict) else {}


def _app_from_close_request(data: dict) -> str:
    raw = data.get("app")
    if raw is None:
        return HUB_CLOSE_APP
    s = str(raw).strip()
    return s if s else HUB_CLOSE_APP


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        raw = self.path.split("?", 1)[0]
        path = raw if raw == "/" else raw.rstrip("/") or "/"
        if path != "/close-tunnel":
            self.send_error(404, "Not Found")
            return
        app = _app_from_close_request(_read_post_json(self))
        ok, msg = _run_close_tunnel(app)
        payload: dict[str, object] = {"ok": ok, "app": app}
        if ok:
            payload["message"] = msg
        else:
            payload["error"] = msg
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200 if ok else 500)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        _wfile_write_ignore_disconnect(self.wfile, body)

    def do_GET(self) -> None:
        raw = self.path.split("?", 1)[0]
        path = raw if raw == "/" else raw.rstrip("/") or "/"

        if path == "/readme.md":
            body = _readme_md_raw()
            self.send_response(200)
            self.send_header("Content-Type", "text/markdown; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            _wfile_write_ignore_disconnect(self.wfile, body)
            return

        if path == "/quickuse.md":
            body = _quickuse_md_raw()
            self.send_response(200)
            self.send_header("Content-Type", "text/markdown; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            _wfile_write_ignore_disconnect(self.wfile, body)
            return

        handler_fn = GET_HANDLERS.get(path)
        if handler_fn is None:
            self.send_error(404, "Not Found")
            return
        body = handler_fn()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        _wfile_write_ignore_disconnect(self.wfile, body)

    def log_message(self, fmt: str, *args) -> None:
        print("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), fmt % args))


def main() -> None:
    if sys.version_info < (3, 7):
        print("serve.py needs Python 3.7+", file=sys.stderr)
        sys.exit(1)
    httpd = HTTPServer((HOST, PORT), Handler)
    base = "http://%s:%s" % (HOST, PORT)
    print("Listening on %s/" % base)
    print("Available URLs:")
    for urlpath, desc, _fn in ROUTES:
        print("  %s%s — %s" % (base, urlpath, desc))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
