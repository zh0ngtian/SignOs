#!/usr/bin/env python3
"""Run production signing/install queue regression on a booted iOS simulator."""
import argparse
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="signos-auto-sign-test-") as directory:
        output = Path(directory)
        app = output / "AutoSignManagerRegression.app"
        app.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        common = ["xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
                  "-module-cache-path", str(output / "ModuleCache")]
        env = {**os.environ, "SDKROOT": sdk}
        empty = output / "Empty.swift"
        empty.write_text("import Foundation\n")
        for name in ("IDeviceSwift", "NimbleExtensions"):
            subprocess.run(common + ["-emit-module", "-module-name", name, str(empty),
                            "-emit-module-path", str(output / f"{name}.swiftmodule")], check=True, env=env)
        binary = app / "AutoSignManagerRegression"
        subprocess.run(common + ["-I", str(output), *[str(ROOT / source) for source in [
            "Feather/Backend/Observable/AutoSignManager.swift",
            "NimbleKit/Sources/NimbleExtensions/String/String+localized.swift",
            "Tests/AutoSignManagerRegression.swift"]], "-o", str(binary)], check=True, env=env)
        bundle_id = "com.signos.auto-sign-test-" + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": binary.name,
            "CFBundleName": "Auto Sign Regression", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
        }))
        try:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            result = subprocess.run(["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id],
                                    check=True, timeout=60, capture_output=True, text=True)
            print(result.stdout)
            print(result.stderr)
            if "AutoSignManagerRegression passed:" not in result.stdout:
                raise RuntimeError("Auto sign regression did not report success")
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)


if __name__ == "__main__":
    main()
