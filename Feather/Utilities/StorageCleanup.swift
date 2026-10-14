import Foundation

enum StorageCleanup {
    struct Package: Sendable {
        let uuid: String
        let identifier: String?
        let version: String?
        let date: Date?
        let sourceVersionID: String?
        let canRemove: Bool
        let isAvailable: Bool
        var isSourceManaged = false
    }

    struct Report: Sendable {
        var removed = 0
        var failures: [String] = []
    }

    static func superseded(in signed: [Package]) -> [String] {
        var newest: [String: Date] = [:]
        for app in signed where app.isAvailable {
            guard let identifier = app.identifier, !identifier.isEmpty else { continue }
            newest[identifier] = max(newest[identifier] ?? .distantPast, app.date ?? .distantPast)
        }
        return signed.compactMap { app in
            guard app.canRemove, let identifier = app.identifier, let date = newest[identifier],
                  (app.date ?? .distantPast) < date else { return nil }
            return app.uuid
        }
    }

    static func duplicates(imported: [Package], signed: [Package]) -> [String] {
        imported.compactMap { app in
            guard app.canRemove, let identifier = app.identifier, !identifier.isEmpty else { return nil }
            let hasSignedCopy = signed.contains { copy in
                guard copy.isAvailable, copy.canRemove, copy.identifier == identifier else { return false }
                if app.isSourceManaged || copy.isSourceManaged || app.sourceVersionID != nil || copy.sourceVersionID != nil {
                    guard let sourceVersion = app.sourceVersionID, !sourceVersion.isEmpty else { return false }
                    return sourceVersion == copy.sourceVersionID
                }
                guard let version = app.version, !version.isEmpty else { return false }
                return version == copy.version
            }
            return hasSignedCopy ? app.uuid : nil
        }
    }

    static func remove<T>(_ items: [T], delete: (T) throws -> Void) -> Report {
        var report = Report()
        for item in items {
            do {
                try delete(item)
                report.removed += 1
            } catch {
                report.failures.append(error.localizedDescription)
            }
        }
        return report
    }

    static func clearArchives(at directory: URL) throws -> Report {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return remove(entries) { try manager.removeItem(at: $0) }
    }

    static func directorySize(at directory: URL) -> Int64 {
        guard let entries = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in entries {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
