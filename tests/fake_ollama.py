"""Minimal stand-in for the Ollama HTTP API used by the tests.

Serves /api/version and /api/tags, and records /api/pull requests.
Usage: python3 fake_ollama.py PORT MODEL[,MODEL...]
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
MODELS = [m for m in (sys.argv[2] if len(sys.argv) > 2 else "").split(",") if m]


class Handler(BaseHTTPRequestHandler):
    def _send(self, body, code=200):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/version":
            self._send({"version": "0.99.0-fake"})
        elif self.path == "/api/tags":
            self._send({"models": [{"name": m, "model": m} for m in MODELS]})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/pull":
            name = body.get("model", "")
            MODELS.append(name if ":" in name else name + ":latest")
            self._send({"status": "success"})
        else:
            self._send({"error": "not found"}, 404)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
