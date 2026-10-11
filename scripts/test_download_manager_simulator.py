#!/usr/bin/env python3
"""Run the actual download manager against a counting HTTP server in iOS Simulator.

Usage: python3 scripts/test_download_manager_simulator.py SIMULATOR_UDID
       python3 scripts/test_download_manager_simulator.py SIMULATOR_UDID --benchmark URL
The simulator must be booted. App signing, import and notifications are stubbed.
"""
import argparse
import collections
import http.server
import json
import os
import pathlib
import platform
import plistlib
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.counts = collections.Counter()
        self.lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/counts":
            with self.server.lock:
                data = json.dumps(dict(self.server.counts)).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        with self.server.lock:
            self.server.counts[self.path] += 1
        size = 2048 if self.path == "/finish.ipa" else 8 * 1024 * 1024
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            for offset in range(0, size, 8192):
                self.wfile.write(b"x" * min(8192, size - offset))
                self.wfile.flush()
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    parser.add_argument("--benchmark")
    args = parser.parse_args()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    with tempfile.TemporaryDirectory(prefix="signos-download-test-") as directory:
        app = pathlib.Path(directory) / "DownloadManagerRegression.app"
        app.mkdir()
        binary = app / "DownloadManagerRegression"
        bundle_id = "com.signos.download-regression.test-" + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": binary.name,
            "CFBundleName": "Download Regression", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        }))
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(pathlib.Path(directory) / "ModuleCache"),
                        "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
                        str(ROOT / "Feather/Backend/Observable/DownloadManager.swift"),
                        str(ROOT / "Tests/DownloadManagerSimulatorRegression.swift"), "-o", str(binary)],
                       check=True, env={**os.environ, "SDKROOT": sdk})
        server = Server()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = args.benchmark or f"http://127.0.0.1:{server.server_port}"
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            command = ["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id, url]
            if args.benchmark:
                command.append("--benchmark")
            subprocess.run(command, check=True, timeout=510 if args.benchmark else 45)
            if not args.benchmark:
                # Count on the server as well as checking task identity inside the client.
                assert server.counts["/finish.ipa"] == 1, server.counts
                # Only the first transfer is allowed to receive data; later provenance checks cancel immediately.
                assert server.counts["/slow.ipa"] <= 3, server.counts
                print(f"Server request counts: {dict(server.counts)}")
        finally:
            server.shutdown()
            server.server_close()
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)


if __name__ == "__main__":
    main()
