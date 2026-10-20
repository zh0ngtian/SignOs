// Production downloader and persistence; only signing/import/UI integrations are replaced.
import Foundation
import CryptoKit
import Darwin

struct SourceAppProvenance: Codable, Sendable {
    var sourceRepositoryURL = URL(string: "https://example.com/source.json")!
    var sourceRepositoryIdentifier: String? = "fixture.source"
    var sourceAppIdentifier = "fixture.app"
    var sourceVersionID = "fixture|1"
}
@MainActor enum AppOperations {
    static var errors: [String] = []
    static func showError(_ message: String) { errors.append(message) }
    static func resumeDeferredUpdates() {}
}
@MainActor final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    func start() {}
    func stop() {}
}
@MainActor final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    func startTask(for id: String, filename: String) {}
    func stopTask(for id: String, success: Bool) {}
    func updateProgress(for id: String, progress: Double) {}
}
@MainActor enum FR {
    struct Receipt { let bytes: Int; let sha256: String; let provenance: SourceAppProvenance?; let target: String? }
    static var receipts: [String: Receipt] = [:]
    static var counts: [String: Int] = [:]
    static var callbacks: [String: (Error?) -> Void] = [:]
    static func handlePackageFile(_ url: URL, download: Download, completion: @escaping (Error?) -> Void) {
        let data = try! Data(contentsOf: url)
        receipts[download.id] = Receipt(bytes: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                        provenance: download.sourceProvenance, target: download.targetAppUUID)
        counts[download.id, default: 0] += 1
        callbacks[download.id] = completion
    }
    static func finish(_ id: String) { callbacks.removeValue(forKey: id)?(nil) }
}

@main
struct DownloadManagerSimulatorRegression {
    @MainActor static func wait(_ description: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            precondition(Date() < deadline, "Timed out: \(description)")
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    static func get(_ path: String, base: URL) async throws -> Data {
        try await URLSession.shared.data(from: URL(string: path, relativeTo: base)!.absoluteURL).0
    }
    @MainActor static func complete(_ download: Download, manager: DownloadManager, sha: String) async throws {
        try await wait("import of \(download.id)") { FR.receipts[download.id] != nil }
        precondition(download.state == .importing && FR.receipts[download.id]!.sha256 == sha)
        precondition(FR.counts[download.id] == 1)
        FR.finish(download.id)
        try await wait("download cleanup") { manager.getDownload(by: download.id) == nil }
    }

    @MainActor static func main() async throws {
        UserDefaults.standard.set(false, forKey: "SignOs.notificationsEnabled")
        let base = URL(string: CommandLine.arguments[1])!
        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "normal"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = try DownloadTransferStore(root: support.appendingPathComponent("DownloadRegression", isDirectory: true))
        let manager = DownloadManager(store: store)
        let fixture = try JSONSerialization.jsonObject(with: await get("/fixture.json", base: base)) as! [String: Any]
        let sha = fixture["sha256"] as! String, changedSHA = fixture["changedSHA256"] as! String
        let size = fixture["bytes"] as! Int

        if mode == "prepare-kill" {
            let download = manager.startDownload(from: base.appendingPathComponent("restart.ipa"), id: "restart",
                sourceProvenance: SourceAppProvenance(), targetAppUUID: "baseline-uuid")
            try await wait("bytes before forced termination") { download.bytesDownloaded > 262144 }
            print("READY_TO_TERMINATE")
            fflush(nil)
            while true {
                precondition(manager.getDownload(by: "restart") != nil)
                try await Task.sleep(for: .seconds(1))
            }
        }
        if mode == "restore" {
            let before = try JSONSerialization.jsonObject(with: await get("/stats", base: base)) as! [String: Any]
            guard let restored = manager.getDownload(by: "restart") else { preconditionFailure("Checkpoint was not restored") }
            precondition(restored.state == .paused && restored.bytesDownloaded > 0 && restored.bytesDownloaded < size)
            precondition(restored.sourceProvenance?.sourceVersionID == "fixture|1" && restored.targetAppUUID == "baseline-uuid")
            try await Task.sleep(for: .milliseconds(250))
            let after = try JSONSerialization.jsonObject(with: await get("/stats", base: base)) as! [String: Any]
            precondition((before["requests"] as! [[String: Any]]).count == (after["requests"] as! [[String: Any]]).count,
                         "Restoring the app automatically resumed a download")
            manager.resumeDownload(restored)
            try await wait("resumed import") { FR.receipts["restart"] != nil }
            precondition(FR.receipts["restart"]!.bytes == size && FR.receipts["restart"]!.sha256 == sha)
            precondition(FR.receipts["restart"]!.provenance?.sourceVersionID == "fixture|1")
            precondition(FR.receipts["restart"]!.target == "baseline-uuid")
            let repeated = manager.startDownload(from: restored.url, id: "duplicate", sourceProvenance: SourceAppProvenance(), targetAppUUID: "baseline-uuid")
            precondition(repeated === restored && FR.counts["restart"] == 1)
            FR.finish("restart")
            try await wait("restored download cleanup") { manager.downloads.isEmpty }
            precondition(store.load().records.isEmpty)
            print("PASS: forced process termination, retained partial files, manual resume, provenance, target identity and single import")
            return
        }

        precondition(manager.downloads.isEmpty)
        let url = base.appendingPathComponent("range.ipa")
        let first = manager.startDownload(from: url, id: "first")
        try await wait("initial parallel bytes") { first.bytesDownloaded > 262144 }
        for i in 0..<8 { precondition(manager.startDownload(from: url, id: "duplicate-\(i)") === first) }
        manager.pauseDownload(first)
        try await wait("pause") { first.state == .paused }
        let saved = first.bytesDownloaded
        precondition(saved > 0 && saved < size)
        try await Task.sleep(for: .milliseconds(100))
        precondition(first.bytesDownloaded == saved)
        manager.resumeDownload(first)
        try await complete(first, manager: manager, sha: sha)
        print("PASS: duplicate coalescing, partial pause, continuation and import exactly once")

        let failed = manager.startDownload(from: base.appendingPathComponent("disconnect.ipa"), id: "failure")
        try await wait("network failure") { failed.state == .failed }
        precondition(failed.bytesDownloaded > 0 && FR.receipts[failed.id] == nil)
        _ = try await get("/control?operation=heal", base: base)
        manager.resumeDownload(failed)
        try await complete(failed, manager: manager, sha: sha)
        print("PASS: failure retains downloaded bytes and can continue")

        let unsupported = manager.startDownload(from: base.appendingPathComponent("ignore.ipa"), id: "unsupported")
        try await wait("unsupported Range prompt") { unsupported.state == .requiresRestart }
        precondition(unsupported.bytesDownloaded == 0)
        manager.resumeDownload(unsupported)
        try await Task.sleep(for: .milliseconds(100))
        precondition(unsupported.state == .requiresRestart)
        manager.restartDownload(unsupported)
        try await wait("confirmed new task") { manager.getDownload(by: "unsupported") !== unsupported }
        let single = manager.getDownload(by: "unsupported")!
        precondition(single.checkpointID != unsupported.checkpointID)
        try await wait("single stream partial data") { single.bytesDownloaded > 262144 }
        manager.pauseDownload(single)
        try await wait("single paused") { single.state == .paused }
        let singleBytes = single.bytesDownloaded
        manager.resumeDownload(single)
        try await wait("single stream requires another confirmation") { single.state == .requiresRestart }
        precondition(single.bytesDownloaded == singleBytes)
        manager.restartDownload(single)
        try await wait("new single stream task") { manager.getDownload(by: "unsupported") !== single }
        try await complete(manager.getDownload(by: "unsupported")!, manager: manager, sha: sha)
        print("PASS: unsupported resume never silently discards data or starts over")

        let mutable = manager.startDownload(from: base.appendingPathComponent("mutable.ipa"), id: "mutable")
        try await wait("mutable prefix") { mutable.bytesDownloaded > 262144 }
        manager.pauseDownload(mutable)
        try await wait("mutable paused") { mutable.state == .paused }
        let oldBytes = mutable.bytesDownloaded
        _ = try await get("/control?operation=mutate", base: base)
        manager.resumeDownload(mutable)
        try await wait("changed file prompt") { mutable.state == .requiresRestart }
        precondition(mutable.bytesDownloaded == oldBytes)
        manager.restartDownload(mutable)
        try await wait("changed task replacement") { manager.getDownload(by: "mutable") !== mutable }
        try await complete(manager.getDownload(by: "mutable")!, manager: manager, sha: changedSHA)
        print("PASS: changed files require confirmation and never mix old and new bytes")

        let manual = manager.startDownload(from: url, id: "manual")
        let source = manager.startDownload(from: url, id: "source", sourceProvenance: SourceAppProvenance())
        precondition(manual !== source && manager.downloads.count == 2)
        manager.cancelDownload(manual)
        manager.cancelDownload(source)
        try await wait("explicit cancellation files removed") {
            !FileManager.default.fileExists(atPath: store.directory(manual.checkpointID!).path)
                && !FileManager.default.fileExists(atPath: store.directory(source.checkpointID!).path)
        }
        precondition(manager.downloads.isEmpty && store.load().records.isEmpty)
        print("PASS: provenance isolation and explicit cancellation cleanup")

        let gated = manager.startDownload(from: base.appendingPathComponent("range.ipa"), id: "gated", sourceProvenance: SourceAppProvenance())
        try await wait("source progress") { gated.bytesDownloaded > 262144 }
        manager.pauseDownload(gated)
        try await wait("source paused") { gated.state == .paused }
        let pausedBytes = gated.bytesDownloaded
        UserDefaults.standard.set(Array(SourcePolicy.keys(url: gated.sourceProvenance!.sourceRepositoryURL,
            identifier: gated.sourceProvenance!.sourceRepositoryIdentifier)), forKey: "SignOs.disabledSources")
        let beforeGate = try JSONSerialization.jsonObject(with: await get("/stats", base: base)) as! [String: Any]
        manager.resumeDownload(gated)
        try await Task.sleep(for: .milliseconds(100))
        let afterGate = try JSONSerialization.jsonObject(with: await get("/stats", base: base)) as! [String: Any]
        precondition(gated.state == .paused && gated.bytesDownloaded == pausedBytes && !AppOperations.errors.isEmpty)
        precondition((beforeGate["requests"] as! [[String: Any]]).count == (afterGate["requests"] as! [[String: Any]]).count)
        UserDefaults.standard.removeObject(forKey: "SignOs.disabledSources")
        manager.cancelDownload(gated)
        try await wait("gated cleanup") { !FileManager.default.fileExists(atPath: store.directory(gated.checkpointID!).path) }
        print("PASS: disabled sources cannot resume retained checkpoints")

        let committed = DownloadCheckpoint(id: UUID(), url: url,
            context: try JSONSerialization.data(withJSONObject: ["id": "committed"]), fileName: "committed.ipa")
        try store.save(committed)
        try Data(committed.id.uuidString.utf8).write(to: store.directory(committed.id).appendingPathComponent("imported"))
        let relaunched = DownloadManager(store: store)
        precondition(relaunched.downloads.isEmpty && !FileManager.default.fileExists(atPath: store.directory(committed.id).path))
        print("PASS: committed imports are not imported again after restart")
        print("DownloadManagerSimulatorRegression passed")
    }
}
