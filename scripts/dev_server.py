#!/usr/bin/env python3
"""Local preview and speedtest endpoint server for ТестНет.рф."""

from __future__ import annotations

import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import time
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
SITE_DIR = (ROOT / "site").resolve()
PAYLOAD_1M = os.urandom(1024 * 1024)
PAYLOAD_4M = os.urandom(4 * 1024 * 1024)
MAX_UPLOAD_BYTES = 16 * 1024 * 1024

CSP_HEADER = (
    "default-src 'self'; script-src 'self'; style-src 'self'; "
    "img-src 'self' data:; connect-src 'self'; font-src 'self'; "
    "manifest-src 'self'; object-src 'none'; base-uri 'none'; "
    "frame-ancestors 'none'; form-action 'self'"
)

BLOCKED_SUFFIXES = (".env", ".git", ".sql", ".bak", ".log", ".ini", ".conf")


class SpeedtestHandler(BaseHTTPRequestHandler):
    """Serve static site assets and local speedtest measurement endpoints."""

    server_version = "TestNetLocal"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        return

    def _send_security_headers(self, cache_control: str | None = None) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.send_header("Permissions-Policy", "camera=(), geolocation=(), microphone=(), focus-without-user-activation=()")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Content-Security-Policy", CSP_HEADER)
        if cache_control:
            self.send_header("Cache-Control", cache_control)

    def _send_bytes(self, status: int, content_type: str, data: bytes, cache_control: str | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self._send_security_headers(cache_control)
        self.end_headers()
        self.wfile.write(data)

    def _send_404(self) -> None:
        not_found = SITE_DIR / "404.html"
        body = not_found.read_bytes() if not_found.is_file() else b"404 Not Found"
        self._send_bytes(HTTPStatus.NOT_FOUND, "text/html; charset=utf-8", body, "no-store")

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(urlparse(self.path).path)
        if path == "/api/ping":
            payload = json.dumps({"ok": True, "ts": f"{time.time():.3f}"}).encode("utf-8")
            self._send_bytes(HTTPStatus.OK, "application/json", payload, "no-store, no-cache, must-revalidate")
            return
        if path == "/api/meta":
            payload = json.dumps({
                "ok": True,
                "tls": "Local-HTTP",
                "cipher": "NONE",
                "http": "HTTP/1.1",
                "node": "RU-MSK-01",
                "ts": f"{time.time():.3f}",
            }).encode("utf-8")
            self._send_bytes(HTTPStatus.OK, "application/json", payload, "no-store, no-cache, must-revalidate")
            return
        if path == "/speed/payload-1m.bin":
            self._send_bytes(HTTPStatus.OK, "application/octet-stream", PAYLOAD_1M, "no-store, no-cache, must-revalidate")
            return
        if path == "/speed/payload-4m.bin":
            self._send_bytes(HTTPStatus.OK, "application/octet-stream", PAYLOAD_4M, "no-store, no-cache, must-revalidate")
            return

        rel = "index.html" if path == "/" else path.lstrip("/")
        if not rel or rel.startswith(".") or "/." in rel or rel.lower().endswith(BLOCKED_SUFFIXES):
            self._send_404()
            return

        candidate = (SITE_DIR / rel).resolve()
        try:
            candidate.relative_to(SITE_DIR)
        except ValueError:
            self._send_404()
            return

        if candidate.is_dir():
            candidate = candidate / "index.html"
        if not candidate.is_file():
            self._send_404()
            return

        ctype, _ = mimetypes.guess_type(str(candidate))
        if candidate.suffix == ".webmanifest":
            ctype = "application/manifest+json"
        if ctype and (ctype.startswith("text/") or ctype in ("application/javascript", "application/json")):
            ctype = f"{ctype}; charset=utf-8"
        self._send_bytes(HTTPStatus.OK, ctype or "application/octet-stream", candidate.read_bytes())

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path != "/api/upload":
            self._send_404()
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length < 0 or length > MAX_UPLOAD_BYTES:
            self.send_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            self._send_security_headers("no-store")
            self.end_headers()
            return
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        self.send_response(HTTPStatus.NO_CONTENT)
        self._send_security_headers("no-store")
        self.end_headers()


def create_server(host: str = "127.0.0.1", port: int = 8765) -> ThreadingHTTPServer:
    """Create a threaded local preview server bound to host:port."""
    return ThreadingHTTPServer((host, port), SpeedtestHandler)


def main() -> None:
    parser = argparse.ArgumentParser(description="Local preview server for ТестНет.рф")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    srv = create_server(args.host, args.port)
    print(f"ТестНет.рф preview server running at http://{args.host}:{srv.server_address[1]}/")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
