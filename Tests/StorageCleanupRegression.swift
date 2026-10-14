import Foundation

@main
struct StorageCleanupRegression {
    @MainActor
    static func main() throws {
        func package(_ uuid: String, identifier: String? = "test.app", version: String? = "1",
                     date: TimeInterval = 1, source: String? = nil,
                     removable: Bool = true, available: Bool = true, managed: Bool = false) -> StorageCleanup.Package {
            .init(uuid: uuid, identifier: identifier, version: version, date: Date(timeIntervalSince1970: date),
                  sourceVersionID: source, canRemove: removable, isAvailable: available, isSourceManaged: managed || source != nil)
        }
        let old = package("old", source: "source|app|1")
        let latest = package("latest", version: "2", date: 2, source: "source|app|2")
        let disabled = package("disabled", removable: false)
        let busy = package("busy", removable: false)
        precondition(StorageCleanup.superseded(in: [old, latest, disabled, busy]) == ["old"],
                     "Enabled source copies participate; disabled, busy and latest packages survive")
        precondition(StorageCleanup.superseded(in: [old, package("missing", date: 3, available: false)]).isEmpty,
                     "A missing newer package cannot justify deleting the only usable package")
        precondition(StorageCleanup.superseded(in: [old, package("clone", identifier: "test.clone", date: 3)]).isEmpty)
        precondition(StorageCleanup.superseded(in: [old, package("tie", date: 1)]).isEmpty)
        precondition(StorageCleanup.superseded(in: [package("no-id", identifier: nil), latest]).isEmpty)

        let signed = [package("signed", version: "2", source: "source|app|2"), package("manual-signed")]
        let imported = [package("duplicate", version: "2", source: "source|app|2"),
                        package("new-version", version: "3", source: "source|app|3"),
                        package("other-source", version: "2", source: "other|app|2"),
                        package("other-entry", version: "2", source: "source|variant|2"),
                        package("manual-duplicate"), package("unknown-version", version: nil),
                        package("protected", version: "2", source: "source|app|2", removable: false)]
        precondition(StorageCleanup.duplicates(imported: imported, signed: signed) == ["duplicate", "manual-duplicate"],
                     "Only the same retained source version or explicit manual version is a duplicate")
        precondition(StorageCleanup.duplicates(imported: [old], signed: [package("missing", source: "source|app|1", available: false)]).isEmpty)
        precondition(StorageCleanup.duplicates(imported: [old], signed: [package("pending", source: "source|app|1", removable: false)]).isEmpty)
        precondition(StorageCleanup.duplicates(imported: [package("legacy", managed: true)], signed: [package("manual")]).isEmpty,
                     "Source packages lacking provenance must not be mistaken for manual duplicates")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("export.ipa"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("empty"), withIntermediateDirectories: true)
        precondition(StorageCleanup.directorySize(at: directory) == 3, "Directory entries must not inflate byte totals")
        let result = try StorageCleanup.clearArchives(at: directory)
        precondition(result.removed == 2 && result.failures.isEmpty)
        precondition(FileManager.default.fileExists(atPath: directory.path), "Keep the archive directory")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(remaining.isEmpty)
        let empty = try StorageCleanup.clearArchives(at: directory)
        precondition(empty.removed == 0)
        let file = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        do {
            _ = try StorageCleanup.clearArchives(at: file)
            preconditionFailure("A filesystem error must be reported")
        } catch { }
        let partial = StorageCleanup.remove(["ok", "failed"]) { uuid in
            if uuid == "failed" { throw CocoaError(.fileWriteNoPermission) }
        }
        precondition(partial.removed == 1 && partial.failures.count == 1, "Count actual successes and retain errors")
        let suite = "StorageCleanupRegression-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let retention = InstallPackageRetention(defaults: defaults)
        defaults.set(Data(#"{"legacy":{"signed":["old"],"imported":["input"],"manuallyDeletedImports":[]}}"#.utf8),
                     forKey: "SignOs.pendingInstallCleanup")
        precondition(retention.protectedPackageUUIDs == ["legacy", "old", "input"], "Old persisted plans remain readable")
        retention.scheduleAfterSigning(for: "new-signature", protected: ["legacy", "old", "input", "new-signature"])
        retention.installationEnded(for: "new-signature", replaceOldVersions: true) { _, _ in }
        precondition(retention.protectedPackageUUIDs == ["legacy", "old", "input"],
                     "Missing legacy markers must never imply that an outstanding installation can be superseded")
        defaults.removeObject(forKey: "SignOs.pendingInstallCleanup")
        retention.scheduleAfterSigning(for: "manual-a", protected: ["manual-a", "input"])
        retention.scheduleAfterSigning(for: "manual-b", protected: ["manual-a", "manual-b", "input"])
        let reloaded = InstallPackageRetention(defaults: defaults)
        precondition(reloaded.protectedPackageUUIDs == ["manual-a", "manual-b", "input"])
        reloaded.beginInstallation(for: "manual-b", protected: ["manual-a", "manual-b", "input"])
        reloaded.installationEnded(for: "manual-b", replaceOldVersions: true) { _, _ in
            preconditionFailure("Protection must not change automatic deletion preferences")
        }
        precondition(reloaded.protectedPackageUUIDs.isEmpty, "Installing the latest signature releases superseded unstarted plans")
        reloaded.scheduleAfterSigning(for: "active-a", protected: ["active-a", "input"])
        reloaded.beginInstallation(for: "active-a", protected: ["active-a", "input"])
        reloaded.scheduleAfterSigning(for: "manual-c", protected: ["active-a", "manual-c", "input"])
        reloaded.installationEnded(for: "manual-c", replaceOldVersions: true) { _, _ in }
        precondition(reloaded.protectedPackageUUIDs == ["active-a", "input"], "Another outstanding install must stay protected")
        reloaded.installationEnded(for: "active-a", replaceOldVersions: true) { _, _ in }
        precondition(reloaded.protectedPackageUUIDs.isEmpty)
        reloaded.schedule(for: "outstanding", imported: ["original-input"])
        reloaded.beginInstallation(for: "outstanding", protected: ["outstanding", "original-input"])
        reloaded.scheduleAfterSigning(for: "automatic-result", protected: ["outstanding", "original-input", "automatic-result"])
        reloaded.schedule(for: "automatic-result", signed: ["outstanding"], imported: ["original-input"])
        reloaded.beginInstallation(for: "automatic-result", protected: ["outstanding", "automatic-result", "original-input"])
        var deleted: Set<String> = []
        reloaded.installationEnded(for: "automatic-result", replaceOldVersions: true) { uuid, _ in deleted.insert(uuid) }
        precondition(deleted.isEmpty && reloaded.protectedPackageUUIDs == ["outstanding", "original-input"],
                     "Production automatic cleanup must preserve an independent outstanding install and its original input")
        reloaded.installationEnded(for: "outstanding", replaceOldVersions: true) { uuid, _ in deleted.insert(uuid) }
        precondition(deleted == ["original-input"] && reloaded.protectedPackageUUIDs.isEmpty)
        print("StorageCleanupRegression passed: enabled sources, protected packages, versions, clones, missing files, archives, partial failure")
    }
}
