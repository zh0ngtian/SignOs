#!/usr/bin/env python3
"""Exercise production installation-browser lifecycle and UIKit/SwiftUI dismissal on Simulator."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]


class InstallPage(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b'<html style="background-color: black;"></html>')

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 18764), InstallPage)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="signos-install-browser-") as directory:
        output = Path(directory)
        app = output / "InstallationBrowserRegression.app"
        app.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        flags = ["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator",
                 "-module-cache-path", str(output / "ModuleCache")]
        env = {**os.environ, "SDKROOT": sdk}
        subprocess.run(flags + ["-parse-as-library", "-emit-module", "-c", "-module-name", "IDeviceSwift",
            "-emit-module-path", str(output / "IDeviceSwift.swiftmodule"),
            str(ROOT / "IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/InstallerStatusViewModel.swift"),
            "-o", str(output / "IDeviceSwift.o")], check=True, env=env)
        subprocess.run(flags + ["-I", str(output), str(output / "IDeviceSwift.o"),
            *[str(ROOT / source) for source in [
                "Feather/Utilities/InstallationBrowserSession.swift",
                "NimbleKit/Sources/NimbleViews/UIKit/SafariRepresentableView.swift",
                "Tests/InstallationBrowserRegression.swift"]],
            "-o", str(app / "InstallationBrowserRegression")], check=True, env=env)
        bundle_id = "com.signos.install-browser-test-" + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "InstallationBrowserRegression",
            "CFBundleName": "Installation Browser Regression", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
        }))
        try:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            result = subprocess.run(["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id],
                                    timeout=90, capture_output=True, text=True)
            (args.evidence / "regression.log").write_text(result.stdout + result.stderr)
            print(result.stdout)
            if result.returncode or "InstallationBrowserRegression passed:" not in result.stdout:
                raise RuntimeError("Installation browser regression failed; see evidence log")
            container = Path(subprocess.check_output([
                "xcrun", "simctl", "get_app_container", args.simulator, bundle_id, "data"], text=True).strip())
            for screenshot in (container / "Documents").glob("*.png"):
                shutil.copy2(screenshot, args.evidence / screenshot.name)
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)
            server.shutdown()


if __name__ == "__main__":
    main()
