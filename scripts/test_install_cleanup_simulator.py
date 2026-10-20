#!/usr/bin/env python3
"""Verify production install cleanup with isolated files and Core Data on a booted simulator."""
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
    with tempfile.TemporaryDirectory(prefix="signos-install-cleanup-") as directory:
        output = Path(directory)
        app = output / "InstallCleanupRegression.app"
        app.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        binary = app / "InstallCleanupRegression"
        subprocess.run([
            "xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
            "-module-cache-path", str(output / "ModuleCache"),
            *[str(ROOT / source) for source in [
                "Feather/Utilities/InstallPackageRetention.swift",
                "Feather/Utilities/AppInventory.swift",
                "Feather/Utilities/AppPackageDeletion.swift",
                "Feather/Utilities/StorageCleanup.swift",
                "Feather/Utilities/SourceSubscriptionIdentity.swift",
                "Feather/Backend/Storage/Storage+Shared.swift",
                "Tests/InstallPackageRetentionRegression.swift",
            ]], "-o", str(binary),
        ], check=True, env={**os.environ, "SDKROOT": sdk})
        bundle_id = "com.signos.install-cleanup-test-" + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": binary.name,
            "CFBundleName": "Install Cleanup Regression", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
        }))
        try:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            result = subprocess.run([
                "xcrun", "simctl", "launch", "--console", args.simulator, bundle_id,
            ], check=True, timeout=60, capture_output=True, text=True)
            print(result.stdout)
            print(result.stderr)
            if "InstallPackageRetentionRegression passed:" not in result.stdout:
                raise RuntimeError("Install cleanup regression did not report success")
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)


if __name__ == "__main__":
    main()
