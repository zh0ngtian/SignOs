#!/usr/bin/env python3
"""Exercise production check scheduling on macOS with a gated synchronization operation.

The check phase is extracted from AutoUpdateManager because the remainder uses
iOS signing/notification APIs. Scheduling and cancellation code is not replaced.
Full app builds and Simulator gestures verify the actual UI integration separately.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(source, name):
    start = source.index("    @discardableResult\n" if name == "checkNow" else "\tprivate func " + name)
    opening = source.index("{", source.index("func " + name, start))
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    source = (ROOT / "Feather/Backend/Observable/AutoUpdateManager.swift").read_text()
    # Existing file indentation uses tabs for checkNow.
    source = source.replace("\t@discardableResult\n\tfunc checkNow", "    @discardableResult\n\tfunc checkNow")
    methods = method(source, "checkNow")
    helper = ROOT / "Feather/Utilities/UpdateCheckCoordinator.swift"
    fields = ""
    if helper.exists():
        fields = "private let checkCoordinator = UpdateCheckCoordinator()"
        methods += "\n" + method(source, "_performCheckNow")
    # Stop after the genuine check phase; notification/signing decisions are unchanged.
    marker = "\t\tlastCheckDate = Date()"
    methods = methods[:methods.index(marker)] + marker + "\n        return UpdateManager.shared.updates.count\n    }"
    manager = """
import Foundation
@MainActor final class AutoUpdateManager {
    var isAutoChecking = false
    var lastCheckDate: Date?
    FIELDS
    func _fetchSources() -> [AltSource] { [AltSource()] }
    func _fetchSignedApps() -> [LocalApp] { [] }
    func _fetchImportedApps() -> [LocalApp] { [] }
    METHODS
}
""".replace("FIELDS", fields).replace("METHODS", methods)
    with tempfile.TemporaryDirectory(prefix="signos-owned-check-") as directory:
        out = Path(directory)
        manager_file = out / "AutoUpdateManagerCheckPhase.swift"
        manager_file.write_text(manager)
        files = [manager_file, ROOT / "Tests/AutoUpdateCheckRegression.swift"]
        if helper.exists():
            files.insert(0, helper)
        binary = out / "AutoUpdateCheckRegression"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
                        *map(str, files), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
