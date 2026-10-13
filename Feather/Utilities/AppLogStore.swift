import Foundation
import os

struct AppLogEntry: Codable, Identifiable, Equatable, Sendable {
    enum Level: String, Codable, CaseIterable, Sendable {
        case debug, info, warning, error

        var title: String {
            switch self {
            case .debug: return "调试"
            case .info: return "信息"
            case .warning: return "警告"
            case .error: return "错误"
            }
        }
    }

    static let maximumMessageBytes = 16 * 1024
    let id: UUID
    let date: Date
    let level: Level
    let category: String
    let message: String

    init(id: UUID = UUID(), date: Date = Date(), level: Level, category: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = Self.limited(Self.redacted(category), bytes: 256)
        self.message = Self.limited(Self.redacted(message), bytes: Self.maximumMessageBytes)
    }

    static func filtered(_ entries: [Self], query: String, level: Level?) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (level == nil || entry.level == level) && (query.isEmpty ||
                [entry.message, entry.category, entry.level.title, entry.level.rawValue].contains {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }
    }

    static func exportText(_ entries: [Self], metadata: String, scope: String, date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = "SignOs 日志\n\(metadata)\n导出时间：\(formatter.string(from: date))\n范围：\(redacted(scope))\n记录：\(entries.count) 条\n"
        return header + "\n" + entries.sorted { $0.date < $1.date }.map { entry in
            "[\(formatter.string(from: entry.date))] [\(entry.level.rawValue.uppercased()) / \(entry.level.title)] [\(entry.category)]\n\(entry.message)\n"
        }.joined(separator: "\n")
    }

    private static func limited(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let suffix = "\n…（内容已截断）"
        var prefix = Array(text.utf8.prefix(max(0, bytes - suffix.utf8.count)))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return (String(bytes: prefix, encoding: .utf8) ?? "") + suffix
    }

    static func redacted(_ message: String) -> String {
        var output = message
        if let urls = try? NSRegularExpression(pattern: #"[a-z][a-z0-9+.-]*://[^\s<>\"']+"#, options: .caseInsensitive) {
            for match in urls.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                guard var url = URLComponents(string: String(output[range])) else {
                    output.replaceSubrange(range, with: "[地址已隐藏]")
                    continue
                }
                url.user = nil
                url.password = nil
                url.fragment = nil
                if url.query != nil { url.query = "[已隐藏]" }
                if let sanitized = url.string { output.replaceSubrange(range, with: sanitized) }
            }
        }
        for pattern in [
            #"(?i)((?<![\w])[\"']?(?:authorization|password|p12Password|token|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|(?:bearer|basic)\s+[^\s,;}]+|[^\s,;}]+)"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "$1[已隐藏]")
            }
        }
        return output
    }
}

/// All state and file access is confined to this queue. Synchronous producers enqueue
/// before returning; snapshot/export therefore observes every preceding record.
final class AppLogStore: Sendable {
    struct Snapshot: Sendable {
        let entries: [AppLogEntry]
        let error: String?
    }

    private struct Archive: Codable, Sendable {
        var version = 1
        var importedActivity = false
        var entries: [AppLogEntry] = []
    }

    static let didChange = Notification.Name("SignOs.logsChanged")
    static let shared = AppLogStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SignOs/Logs/logs.json"))

    private let queue = DispatchQueue(label: "com.signos.logs", qos: .utility)
    private let fileURL: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private struct State: Sendable {
        var archive = Archive()
        var persistenceError: String?
        var corruptFile = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(fileURL: URL, maximumEntries: Int = 1000, maximumBytes: Int = 2 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1024, maximumBytes)
        state.withLock { state in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= self.maximumBytes else {
                    throw CocoaError(.fileReadTooLarge)
                }
                state.archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard state.archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                state.archive.entries = Array(state.archive.entries.prefix(self.maximumEntries))
            } catch {
                state.corruptFile = true
                state.persistenceError = "读取日志失败：\(error.localizedDescription)"
            }
        }
    }

    func record(_ entry: AppLogEntry) {
        queue.async {
            self.state.withLock { state in
                state.archive.entries.append(entry)
                self.update(&state)
            }
        }
    }

    func importActivityHistory(_ entries: [AppLogEntry]) {
        queue.async {
            self.state.withLock { state in
                guard !state.archive.importedActivity else { return }
                state.archive.importedActivity = true
                state.archive.entries.append(contentsOf: entries)
                self.update(&state)
            }
        }
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let snapshot = self.state.withLock { Snapshot(entries: $0.archive.entries, error: $0.persistenceError) }
                continuation.resume(returning: snapshot)
            }
        }
    }

    func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.state.withLock { state in
                    let previous = state.archive
                    state.archive.entries = []
                    do {
                        try self.persist(&state)
                        state.persistenceError = nil
                        NotificationCenter.default.post(name: Self.didChange, object: nil)
                        continuation.resume()
                    } catch {
                        state.archive = previous
                        state.persistenceError = "清空日志失败：\(error.localizedDescription)"
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func update(_ state: inout State) {
        state.archive.entries.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        state.archive.entries = Array(state.archive.entries.prefix(maximumEntries))
        do {
            try persist(&state)
            state.persistenceError = nil
        } catch {
            state.persistenceError = "保存日志失败：\(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func persist(_ state: inout State) throws {
        let encoder = JSONEncoder()
        var data = try encoder.encode(state.archive)
        while data.count > maximumBytes && !state.archive.entries.isEmpty {
            state.archive.entries.removeLast()
            data = try encoder.encode(state.archive)
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if state.corruptFile && FileManager.default.fileExists(atPath: fileURL.path) {
            let preserved = directory.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).corrupt-\(UUID()).json")
            try FileManager.default.moveItem(at: fileURL, to: preserved)
            state.corruptFile = false
        }
        try data.write(to: fileURL, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
    }
}
