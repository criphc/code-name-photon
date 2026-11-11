#!/usr/bin/env python3
"""Minimal static server for the M0 viewer check (HEIC must be served as image/heic)."""
import http.server, mimetypes, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deliverable")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
mimetypes.add_type("image/heic", ".heic")
mimetypes.add_type("image/heic", ".HEIC")

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write("[serve] " + (fmt % args) + "\n")

print(f"serving {ROOT} on 0.0.0.0:{PORT}", flush=True)
http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
