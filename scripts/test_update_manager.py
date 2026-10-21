#!/usr/bin/env python3
"""Run production update checking and Core Data writing with HTTP fixtures in a booted iOS Simulator."""
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
    with tempfile.TemporaryDirectory(prefix="signos-update-test-") as directory:
        output = Path(directory)
        app = output / "UpdateManagerRegression.app"
        app.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        common = ["xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
                  "-module-cache-path", str(output / "ModuleCache")]
        env = {**os.environ, "SDKROOT": sdk}
        subprocess.run(common + ["-emit-library", "-emit-module", "-module-name", "AltSourceKit",
                        "-emit-module-path", str(output / "AltSourceKit.swiftmodule"),
                        "-Xlinker", "-install_name", "-Xlinker", "@rpath/libAltSourceKit.dylib",
                        *map(str, sorted((ROOT / "AltSourceKit/Sources/AltSourceKit").rglob("*.swift"))),
                        "-o", str(app / "libAltSourceKit.dylib")], check=True, env=env)
        model = app / "Feather.momd"
        subprocess.run(["xcrun", "momc", str(ROOT / "Feather/Backend/Storage/Feather.xcdatamodeld"), str(model)], check=True)
        binary = app / "UpdateManagerRegression"
        subprocess.run(common + ["-I", str(output), "-L", str(app), "-lAltSourceKit",
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                        *[str(ROOT / source) for source in [
                            "Feather/Utilities/AppVersion.swift", "Feather/Utilities/UpdateRelease.swift", "Feather/Utilities/AppInventory.swift", "Feather/Utilities/SourcePolicy.swift",
                            "Feather/Utilities/AppBundleIdentifierPreferences.swift",
                            "Feather/Utilities/SourceRepositoryIdentity.swift", "Feather/Utilities/SourceSubscriptionIdentity.swift",
                            "Feather/Backend/Storage/Storage+SourceMetadata.swift", "Feather/Backend/Observable/UpdateManager.swift",
                            "Feather/Backend/CloudSource/CloudSourceModels.swift", "Feather/Backend/CloudSource/CloudSourceStore.swift",
                            "Feather/Backend/CloudSource/CloudSourceCredentials.swift",
                            "NimbleKit/Sources/NimbleExtensions/String/String+localized.swift",
                            "Tests/UpdateManagerRegression.swift"]], "-o", str(binary)], check=True, env=env)
        subprocess.run(["xcrun", "xcstringstool", "compile", str(ROOT / "Feather/Resources/Localizable.xcstrings"),
                        "--output-directory", str(app), "--language", "zh-Hans", "--language", "en"], check=True)
        bundle_id = "com.signos.update-test-" + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": binary.name,
            "CFBundleName": "Update Regression", "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
        }))
        try:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            # Allow cold CI simulator startup; completion still requires the explicit success marker.
            try:
                result = subprocess.run(["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"],
                                        check=True, timeout=180, capture_output=True, text=True)
            except subprocess.TimeoutExpired as error:
                print(error.stdout or b"")
                print(error.stderr or b"")
                raise
            print(result.stdout)
            print(result.stderr)
            if "UpdateManagerRegression passed:" not in result.stdout:
                raise RuntimeError("Update manager regression did not report success")
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)


if __name__ == "__main__":
    main()
