import Foundation

enum LogExportFile {
    static func write(entries: [AppLogEntry], metadata: String, scope: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SignOsLogExports/\(UUID())", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyyMMdd-HHmmss"
                    let url = directory.appendingPathComponent("SignOs-Logs-\(formatter.string(from: Date())).txt")
                    try AppLogEntry.exportText(entries, metadata: metadata, scope: scope).write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume(returning: url)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
