import Foundation

struct DownloadTransferStore: Sendable {
    let root: URL

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
    }

    static func applicationStore() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try Self(root: support.appendingPathComponent("SignOsDownloads", isDirectory: true))
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func manifest(_ id: UUID) -> URL { directory(id).appendingPathComponent("checkpoint.json") }
    func part(_ id: UUID, _ index: Int) -> URL { directory(id).appendingPathComponent("\(index).part") }
    func assembled(_ id: UUID) -> URL { directory(id).appendingPathComponent("package.ipa") }
    func discarded(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: directory(id).appendingPathComponent("cancelled").path) }

    func save(_ record: DownloadCheckpoint) throws {
        guard !discarded(record.id) else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory(record.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: manifest(record.id), options: .atomic)
    }

    func size(_ url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize else {
            throw DownloadTransferFailure.interrupted("下载缓存文件无法读取，已保留现有数据。")
        }
        return Int64(bytes)
    }

    func markDiscarded(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
        try Data().write(to: directory(id).appendingPathComponent("cancelled"), options: .atomic)
    }

    func remove(_ id: UUID) throws {
        let path = directory(id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    func resetParts(_ record: DownloadCheckpoint) throws {
        for index in 0..<4 {
            let file = part(record.id, index)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        for name in ["package.ipa", "assembling.ipa"] {
            let file = directory(record.id).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    func load() -> (records: [DownloadCheckpoint], issues: [String]) {
        var records: [DownloadCheckpoint] = [], issues: [String] = []
        do {
            for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                do {
                    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                    if discarded(id) { try remove(id); continue }
                    let record = try JSONDecoder().decode(DownloadCheckpoint.self, from: Data(contentsOf: manifest(id)))
                    guard record.id == id, record.schemaVersion == 1, (1...4).contains(record.partCount),
                          ["http", "https"].contains(record.url.scheme?.lowercased() ?? "") else {
                        throw DownloadTransferFailure.interrupted("下载记录格式无效。")
                    }
                    records.append(record)
                } catch { issues.append("一条下载记录无法恢复，原始缓存已保留：\(error.localizedDescription)") }
            }
        } catch { issues.append("下载记录读取失败：\(error.localizedDescription)") }
        return (records, issues)
    }
}
