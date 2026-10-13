import Foundation

@main
struct AppLogRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signos-log-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("logs.json")
        let store = AppLogStore(fileURL: file, maximumEntries: 3, maximumBytes: 1800)
        for index in 0..<5 {
            store.record(AppLogEntry(date: Date(timeIntervalSince1970: Double(index)), level: index == 4 ? .error : .info,
                category: "下载", message: "记录 \(index)\n完整详情"))
        }
        let first = await store.snapshot()
        precondition(first.error == nil)
        precondition(first.entries.count == 3 && first.entries.first?.message.contains("记录 4") == true)
        precondition(Set(first.entries.map(\.id)).count == 3)
        let restored = AppLogStore(fileURL: file, maximumEntries: 3, maximumBytes: 1800)
        let reloaded = await restored.snapshot()
        precondition(first.entries == reloaded.entries, "Logs must survive restart")
        let filtered = AppLogEntry.filtered(first.entries, query: "完整详情", level: .error)
        precondition(filtered.count == 1)
        precondition(AppLogEntry.filtered(first.entries, query: " 下载 ", level: nil).count == 3)
        precondition(AppLogEntry.filtered(first.entries, query: "INFO", level: nil).count == 2)
        let text = AppLogEntry.exportText(first.entries, metadata: "SignOs 1.2.3 (42)\niOS 26.5", scope: "全部日志")
        precondition(text.contains("SignOs 1.2.3 (42)") && text.contains("完整详情"))
        precondition(text.range(of: "记录 2")!.lowerBound < text.range(of: "记录 4")!.lowerBound)
        let exportFile = try await LogExportFile.write(entries: filtered, metadata: "SignOs 1.2.3 (42)", scope: "错误")
        defer { try? FileManager.default.removeItem(at: exportFile.deletingLastPathComponent()) }
        let exported = try String(contentsOf: exportFile, encoding: .utf8)
        precondition(exportFile.pathExtension == "txt" && exported.contains("记录 4") && !exported.contains("记录 3"))
        let sensitive = "https://user:secret@example.com/file?token=abc&name=private#credential Authorization: Bearer abc123 password=secret Token: token123"
        let redacted = AppLogEntry(level: .error, category: "https://user:secret@example.com", message: sensitive)
        for secret in ["user", "secret", "abc", "private", "credential", "token123"] {
            precondition(!redacted.message.contains(secret), "Sensitive value leaked: \(secret)")
        }
        precondition(!redacted.category.contains("secret"))
        precondition(redacted.message.contains("example.com/file"))
        for input in [
            #"{"Authorization": "Bearer super-secret-token"}"#,
            #"{'password': 'super-secret-password'}"#,
            #"Authorization: "Bearer super-secret-token""#,
            #"{"password":"abc\"remaining-secret"}"#
        ] {
            precondition(!AppLogEntry.redacted(input).contains("secret"), "Quoted credential leaked: \(input)")
        }
        let migrationFile = directory.appendingPathComponent("migration.json")
        let migrating = AppLogStore(fileURL: migrationFile)
        let legacy = AppLogEntry(level: .info, category: "活动", message: "旧活动")
        migrating.importActivityHistory([legacy])
        migrating.importActivityHistory([legacy])
        let migrated = await migrating.snapshot()
        precondition(migrated.entries.count == 1)
        try await migrating.clear()
        let restarted = AppLogStore(fileURL: migrationFile)
        restarted.importActivityHistory([legacy])
        let cleared = await restarted.snapshot()
        precondition(cleared.entries.isEmpty, "Clearing must not reimport activity history")
        let boundedFile = directory.appendingPathComponent("bounded.json")
        let bounded = AppLogStore(fileURL: boundedFile, maximumEntries: 1000, maximumBytes: 24000)
        for index in 0..<12 {
            bounded.record(AppLogEntry(level: .debug, category: "测试", message: "\(index)" + String(repeating: "中", count: 10000)))
        }
        let boundedSnapshot = await bounded.snapshot()
        precondition(boundedSnapshot.error == nil && !boundedSnapshot.entries.isEmpty)
        let boundedData = try Data(contentsOf: boundedFile)
        precondition(boundedData.count <= 24000)
        precondition(boundedSnapshot.entries.allSatisfy { $0.message.utf8.count <= AppLogEntry.maximumMessageBytes })
        let concurrent = AppLogStore(fileURL: directory.appendingPathComponent("concurrent.json"))
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            concurrent.record(AppLogEntry(level: .info, category: "并发", message: String(index)))
        }
        let concurrentResult = await concurrent.snapshot()
        precondition(concurrentResult.entries.count == 100 && Set(concurrentResult.entries.map(\.id)).count == 100)
        let brokenFile = directory.appendingPathComponent("broken.json")
        try Data("corrupted evidence".utf8).write(to: brokenFile)
        let broken = AppLogStore(fileURL: brokenFile)
        let brokenSnapshot = await broken.snapshot()
        precondition(brokenSnapshot.error != nil)
        let brokenData = try Data(contentsOf: brokenFile)
        precondition(brokenData == Data("corrupted evidence".utf8))
        broken.record(AppLogEntry(level: .info, category: "恢复", message: "新日志"))
        let recovered = await broken.snapshot()
        precondition(recovered.entries.count == 1)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(preserved.contains { $0.lastPathComponent.hasPrefix("broken.corrupt-") })
        let failure = AppLogStore(fileURL: directory.appendingPathComponent("absent/child/logs.json"))
        failure.record(AppLogEntry(level: .warning, category: "错误", message: "创建目录"))
        let created = await failure.snapshot()
        precondition(created.error == nil)
        let impossible = AppLogStore(fileURL: file.appendingPathComponent("cannot-write.json"))
        impossible.record(AppLogEntry(level: .error, category: "错误", message: "保留内存"))
        let failed = await impossible.snapshot()
        precondition(failed.entries.count == 1 && failed.error != nil)
        do { try await impossible.clear(); preconditionFailure("A failed clear must report failure") }
        catch { }
        let failedClear = await impossible.snapshot()
        precondition(failedClear.entries.count == 1, "A failed clear must retain in-memory entries")
        print("AppLogRegression: persistence, limits, filtering, redaction, migration, concurrency, export and failures passed")
    }
}
