#!/usr/bin/env python3
"""Minimal HTTP Hello World for hub-tunnel root site (see SETUP.md)."""
import html
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
TITLE = os.environ.get("HELLO_TITLE", "Hello, World")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] != "/":
            self.send_error(404)
            return
        body = (
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>"
            + html.escape(TITLE)
            + "</title></head><body><h1>"
            + html.escape(TITLE)
            + "</h1></body></html>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        print("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), fmt % args))


def main() -> None:
    httpd = HTTPServer((HOST, PORT), Handler)
    print("Listening on http://%s:%s/" % (HOST, PORT))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
