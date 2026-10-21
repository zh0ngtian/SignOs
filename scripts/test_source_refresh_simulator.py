#!/usr/bin/env python3
"""Run production source browsing refresh with HTTP fixtures in an isolated Simulator app."""
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
    with tempfile.TemporaryDirectory(prefix="signos-source-refresh-") as directory:
        output = Path(directory)
        app = output / "SourceRefreshRegression.app"
        app.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        flags = ["xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
                 "-module-cache-path", str(output / "ModuleCache")]
        env = {**os.environ, "SDKROOT": sdk}
        modules = {
            "AltSourceKit": sorted((ROOT / "AltSourceKit/Sources/AltSourceKit").rglob("*.swift")),
            "NimbleJSON": [ROOT / "NimbleKit/Sources/NimbleJSON/NBFetchService.swift"],
        }
        for name, sources in modules.items():
            subprocess.run(flags + ["-emit-library", "-emit-module", "-module-name", name,
                           "-emit-module-path", str(output / f"{name}.swiftmodule"),
                           "-Xlinker", "-install_name", "-Xlinker", f"@rpath/lib{name}.dylib",
                           *map(str, sources), "-o", str(app / f"lib{name}.dylib")], check=True, env=env)
        sources = [
            "Feather/Views/Sources/SourcesViewModel.swift", "Feather/Utilities/SourceSynchronization.swift",
            "Feather/Utilities/SourcePolicy.swift", "Feather/Backend/CloudSource/CloudSourceModels.swift",
            "Feather/Backend/CloudSource/CloudSourceStore.swift",
            "NimbleKit/Sources/NimbleExtensions/String/String+localized.swift", "Tests/SourceRefreshRegression.swift",
        ]
        binary = app / "SourceRefreshRegression"
        subprocess.run(flags + ["-I", str(output), "-L", str(app), "-lAltSourceKit", "-lNimbleJSON",
                       "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                       *[str(ROOT / path) for path in sources], "-o", str(binary)], check=True, env=env)
        bundle_id = "com.signos.source-refresh-test-" + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleExecutable": binary.name,
            "CFBundleName": "Source Refresh Regression", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
        }))
        try:
            subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True)
            result = subprocess.run(["xcrun", "simctl", "launch", "--console", args.simulator, bundle_id],
                                    timeout=90, capture_output=True, text=True)
            print(result.stdout)
            print(result.stderr)
            result.check_returncode()
            if "SourceRefreshRegression passed:" not in result.stdout:
                raise RuntimeError("Source refresh regression did not report success")
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False)


if __name__ == "__main__":
    main()
