#!/usr/bin/env python3
"""Verify production downloader pause/retry and forced process restart on Simulator."""
import argparse
import os
import pathlib
import platform
import plistlib
import subprocess
import tempfile
import time
import uuid
from download_test_server import DownloadFixtureServer
from test_segmented_download import CORE

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    args = parser.parse_args()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    with tempfile.TemporaryDirectory(prefix="signos-download-test-") as directory:
        output = pathlib.Path(directory)
        app = output / "DownloadManagerRegression.app"
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
        sources = [str(ROOT / "Feather/Backend/Download" / name) for name in CORE]
        sources += [str(ROOT / name) for name in [
            "NimbleKit/Sources/NimbleExtensions/String/String+localized.swift",
            "Feather/Utilities/SourcePolicy.swift", "Feather/Utilities/AppLogStore.swift",
            "Feather/Utilities/AppLogger.swift", "Feather/Backend/Download/Download.swift",
            "Feather/Backend/Observable/DownloadManager.swift", "Tests/DownloadManagerSimulatorRegression.swift"]]
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(output / "ModuleCache"),
                        "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator", *sources, "-o", str(binary)],
                       check=True, env={**os.environ, "SDKROOT": sdk})
        server = DownloadFixtureServer().start()
        try:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            container = pathlib.Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, bundle_id, "data"], text=True).strip())
            root = container / "Library/Application Support/DownloadRegression"
            log = output / "forced-termination.log"
            with log.open("w") as stream:
                process = subprocess.Popen(["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id, server.url, "prepare-kill"], stdout=stream, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 25
                    while time.monotonic() < deadline:
                        total = sum(f.stat().st_size for f in root.glob("*/*.part") if f.exists())
                        if total >= 262144:
                            break
                        if process.poll() is not None:
                            raise RuntimeError(log.read_text())
                        time.sleep(0.025)
                    else:
                        raise TimeoutError("No persistent bytes before forced termination: " + log.read_text())
                    subprocess.run(["xcrun", "simctl", "terminate", args.simulator, bundle_id], check=True)
                    process.wait(timeout=10)
                    print("Forced termination retained", total, "bytes on disk.")
                finally:
                    if process.poll() is None: process.terminate()
            for mode in ["restore", "normal"]:
                result = subprocess.run(["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id, server.url, mode],
                                        capture_output=True, text=True, timeout=120, check=True)
                print(result.stdout)
                print(result.stderr)
                expected = "PASS: forced process termination" if mode == "restore" else "DownloadManagerSimulatorRegression passed"
                if expected not in result.stdout:
                    raise RuntimeError("Simulator regression did not report success")
            print("Production downloader Simulator regressions passed, including a real process termination.")
        finally:
            server.shutdown()
            server.server_close()
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)


if __name__ == "__main__":
    main()
