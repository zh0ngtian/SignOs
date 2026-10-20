"""Deterministic, local HTTP fixtures for segmented download regressions."""
import collections
import hashlib
import http.server
import json
import socket
import threading
import time
from urllib.parse import parse_qs, urlsplit


class DownloadFixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), DownloadFixtureHandler)
        self.lock = threading.Lock()
        self.body = bytes(range(256)) * 32768
        self.changed_body = bytes(reversed(range(256))) * 32768
        self.version = 1
        self.drop = True
        self.requests = []
        self.active = collections.Counter()
        self.maximum = collections.Counter()
        self.cap_active = 0
        self.cap_maximum = 0
        self.sent = collections.Counter()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_port}"

    def start(self):
        threading.Thread(target=self.serve_forever, daemon=True).start()
        return self

    def snapshot(self):
        with self.lock:
            return {"requests": list(self.requests), "active": dict(self.active), "maximum": dict(self.maximum),
                    "capMaximum": self.cap_maximum, "sent": dict(self.sent)}


class DownloadFixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/stats":
            self.send_json(self.server.snapshot())
            return
        if path == "/fixture.json":
            self.send_json({"bytes": len(self.server.body), "sha256": hashlib.sha256(self.server.body).hexdigest(),
                            "changedSHA256": hashlib.sha256(self.server.changed_body).hexdigest()})
            return
        if path == "/control":
            operation = parse_qs(urlsplit(self.path).query)["operation"][0]
            with self.server.lock:
                if operation == "mutate": self.server.version = 2
                if operation == "heal": self.server.drop = False
            self.send_json({"ok": True})
            return
        if path == "/forbidden.ipa":
            self.send_response(403)
            self.end_headers()
            return
        with self.server.lock:
            version = self.server.version if path == "/mutable.ipa" else 1
            drop = self.server.drop and path == "/disconnect.ipa"
        body = self.server.changed_body if version == 2 else self.server.body
        if path == "/small.ipa": body = body[:2048]
        etag = f'"fixture-{version}"'
        spec = self.headers.get("Range")
        ranged = spec is not None and path != "/ignore.ipa"
        lo, hi = 0, len(body) - 1
        if ranged:
            lo, hi = map(int, spec.removeprefix("bytes=").split("-"))
            if self.headers.get("If-Range") not in (None, etag):
                ranged, lo, hi = False, 0, len(body) - 1
        if lo < 0 or hi < lo or hi >= len(body):
            self.send_response(416)
            self.end_headers()
            return
        probe = spec == "bytes=0-0"
        actual_etag = '"changed-after-probe"' if path == "/racy.ipa" and not probe else etag
        total = len(body) + (1 if path == "/wrong-total.ipa" and not probe else 0)
        reported_lo = lo + (1 if path == "/wrong-range.ipa" and not probe else 0)
        length = hi - lo + 1
        with self.server.lock:
            self.server.requests.append({"path": path, "range": spec, "ifRange": self.headers.get("If-Range"), "version": version})
            if not probe:
                self.server.active[path] += 1
                self.server.maximum[path] = max(self.server.maximum[path], self.server.active[path])
                if path.startswith("/cap"):
                    self.server.cap_active += 1
                    self.server.cap_maximum = max(self.server.cap_maximum, self.server.cap_active)
        counted = not probe
        def finish_body():
            nonlocal counted
            if counted:
                with self.server.lock:
                    self.server.active[path] -= 1
                    if path.startswith("/cap"): self.server.cap_active -= 1
                counted = False
        try:
            self.send_response(206 if ranged else 200)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", "application/octet-stream")
            if path != "/no-validator.ipa": self.send_header("ETag", actual_etag)
            if ranged: self.send_header("Content-Range", f"bytes {reported_lo}-{hi}/{total}")
            self.end_headers()
            for offset in range(lo, hi + 1, 16384):
                data = body[offset:min(offset + 16384, hi + 1)]
                # The last write may wake the client before this handler gets
                # scheduled again. Do not count response teardown as a fifth
                # active body stream after the client has released its permit.
                if offset + len(data) > hi: finish_body()
                self.wfile.write(data)
                self.wfile.flush()
                with self.server.lock:
                    self.server.sent[path] += len(data)
                if drop and not probe and offset - lo >= 65536:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.close_connection = True
                    return
                if not probe and offset + len(data) <= hi: time.sleep(0.02 if path == "/restart.ipa" else 0.003)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            finish_body()
