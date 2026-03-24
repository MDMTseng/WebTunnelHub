#!/usr/bin/env python3
"""Local HTTP server for hub-tunnel: quick `/` for health checks; `/status` runs hub-status.sh (see SETUP.md)."""
import html
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
TITLE = os.environ.get("HELLO_TITLE", "WebTunnelHub")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HUB_STATUS_SH = os.path.join(SCRIPT_DIR, "hub-status.sh")
HUB_STATUS_TIMEOUT = int(os.environ.get("HUB_STATUS_TIMEOUT", "120"))
HUB_BASH = os.environ.get("HUB_BASH", "bash")
STATUS_REFRESH = os.environ.get("HUB_STATUS_REFRESH_SEC", "").strip()


def _run_hub_status():
    if not os.path.isfile(HUB_STATUS_SH):
        return 127, "hub-status.sh not found next to serve.py (%s)" % SCRIPT_DIR
    try:
        proc = subprocess.run(
            [HUB_BASH, HUB_STATUS_SH],
            cwd=SCRIPT_DIR,
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
        '<p><a href="/">Home</a> · Hub status (from <code>hub-status.sh</code>)</p>'
        + banner
        + "<pre>"
        + esc
        + "</pre></body></html>"
    )
    return body.encode("utf-8")


def _page_home() -> bytes:
    body = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>"
        + html.escape(TITLE)
        + "</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:1rem}a{color:#06c}</style>"
        "</head><body><h1>"
        + html.escape(TITLE)
        + "</h1>"
        "<p>Local server is up. Open <a href=\"/status\"><strong>Hub status</strong></a> "
        "for <code>hub-status.sh</code> (SSH to EC2; may take a few seconds).</p>"
        "</body></html>"
    )
    return body.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        raw = self.path.split("?", 1)[0]
        path = raw if raw == "/" else raw.rstrip("/") or "/"

        if path == "/":
            body = _page_home()
        elif path == "/status":
            body = _page_status()
        else:
            self.send_error(404, "Not Found")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        print("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), fmt % args))


def main() -> None:
    if sys.version_info < (3, 7):
        print("serve.py needs Python 3.7+", file=sys.stderr)
        sys.exit(1)
    httpd = HTTPServer((HOST, PORT), Handler)
    print("Listening on http://%s:%s/ (Hub status: /status)" % (HOST, PORT))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
