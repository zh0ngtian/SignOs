// Compile with the production DownloadManager.swift; replace only app integrations.
import Foundation
import Darwin

struct SourceAppProvenance {}
final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    func start() {}
    func stop() {}
}
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    func startTask(for id: String, filename: String) {}
    func stopTask(for id: String, success: Bool) {}
    func updateProgress(for id: String, progress: Double) {}
}
enum FR {
    struct Receipt {
        let bytes: Int
        let responseURL: URL?
        let status: Int?
    }
    static let lock = NSLock()
    static var receipts: [String: Receipt] = [:]
    static func receipt(_ id: String) -> Receipt? {
        lock.lock(); defer { lock.unlock() }
        return receipts[id]
    }
    static func handlePackageFile(_ url: URL, download: Download, completion: @escaping (Error?) -> Void) {
        let bytes = (try? Data(contentsOf: url).count) ?? 0
        try? FileManager.default.removeItem(at: url)
        lock.lock(); defer { lock.unlock() }
        receipts[download.id] = Receipt(bytes: bytes, responseURL: download.task?.response?.url,
                                       status: (download.task?.response as? HTTPURLResponse)?.statusCode)
        // Retain the record to simulate unpacking/importing still in progress.
    }
}
extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
    func removeFileIfNeeded(at url: URL) throws {
        if fileExists(atPath: url.path) { try removeItem(at: url) }
    }
}

final class BenchmarkDownloadManager: DownloadManager {
    private let metricsLock = NSLock()
    private var collectedMetrics: URLSessionTaskMetrics?
    var metrics: URLSessionTaskMetrics? {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return collectedMetrics
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        collectedMetrics = metrics
    }
}

@main
struct DownloadManagerSimulatorRegression {
    @MainActor
    static func wait(_ description: String, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            precondition(Date() < end, "Timed out: \(description)")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    static func main() async throws {
        UserDefaults.standard.set(false, forKey: "SignOs.notificationsEnabled")
        let base = URL(string: CommandLine.arguments[1])!
        if CommandLine.arguments.contains("--benchmark") {
            try await benchmark(base)
            return
        }
        let manager = DownloadManager()
        let url = base.appendingPathComponent("slow.ipa")
        let first = manager.startDownload(from: url, id: "first")
        let originalTask = first.task!
        try await wait("initial bytes") { first.bytesDownloaded > 0 }
        let before = first.bytesDownloaded
        for index in 0..<8 {
            let repeated = manager.startDownload(from: url, id: "repeat-\(index)")
            precondition(repeated === first && repeated.task === originalTask)
        }
        precondition(manager.downloads.count == 1 && first.bytesDownloaded >= before)
        try await wait("continued progress") { first.bytesDownloaded > before }

        originalTask.suspend()
        try await wait("task suspension") { originalTask.state == .suspended }
        let suspendedBytes = first.bytesDownloaded
        manager.resumeDownload(first)
        precondition(first.task === originalTask)
        try await wait("resumed transfer") {
            originalTask.state == .running && first.bytesDownloaded > suspendedBytes
        }
        manager.cancelDownload(first)
        precondition(manager.downloads.isEmpty)
        try await wait("cancellation") { originalTask.state == .completed }

        let canceling = manager.startDownload(from: base.appendingPathComponent("canceling.ipa"))
        let cancelingTask = canceling.task!
        cancelingTask.cancel()
        manager.resumeDownload(canceling)
        precondition(canceling.task === cancelingTask)
        manager.cancelDownload(canceling)

        let finished = manager.startDownload(from: base.appendingPathComponent("finish.ipa"), id: "finished")
        try await wait("finished transfer") { FR.receipt(finished.id) != nil && finished.task?.state == .completed }
        let finishedTask = finished.task!
        let repeatedFinished = manager.startDownload(from: finished.url)
        precondition(repeatedFinished === finished && finished.task === finishedTask)
        manager.cancelDownload(finished)

        let (countsData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("counts"))
        let counts = try JSONSerialization.jsonObject(with: countsData) as! [String: Int]
        precondition(counts["/slow.ipa"] == 1 && counts["/finish.ipa"] == 1,
                     "Repeated calls created extra HTTP requests: \(counts)")

        let manual = manager.startDownload(from: url, id: "manual")
        let source = manager.startDownload(from: url, id: "source", sourceProvenance: SourceAppProvenance())
        precondition(manual !== source && manager.downloads.count == 2)
        manager.cancelDownload(manual)
        manager.cancelDownload(source)
        print("PASS: running/suspended/canceling/completed task reuse, progress, cancellation, provenance separation")
    }

    @MainActor
    static func benchmark(_ url: URL) async throws {
        var directURL: URL?
        for index in 0..<4 {
            let manager = BenchmarkDownloadManager()
            let target = index % 2 == 1 ? directURL! : url
            let start = Date()
            let download = manager.startDownload(from: target, id: "benchmark-\(index)")
            try await wait("benchmark", timeout: 120) { FR.receipt(download.id) != nil && manager.metrics != nil }
            let duration = Date().timeIntervalSince(start)
            let receipt = FR.receipt(download.id)!
            precondition(receipt.status == 200 && receipt.bytes > 0)
            directURL = receipt.responseURL
            let metrics = manager.metrics!
            let transactions: [[String: Any]] = metrics.transactionMetrics.map { transaction in
                func interval(_ start: Date?, _ end: Date?) -> Double {
                    guard let start, let end else { return 0 }
                    return end.timeIntervalSince(start)
                }
                return ["host": transaction.request.url?.host ?? "",
                    "protocol": transaction.networkProtocolName ?? "unknown",
                    "proxy": transaction.isProxyConnection,
                    "firstByteSeconds": interval(transaction.fetchStartDate, transaction.responseStartDate),
                    "bodySeconds": interval(transaction.responseStartDate, transaction.responseEndDate),
                    "dnsSeconds": interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
                    "tlsSeconds": interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)]
            }
            let result: [String: Any] = ["route": index % 2 == 0 ? "github-release" : "resolved-asset",
                "seconds": duration, "bytes": receipt.bytes, "bytesPerSecond": Double(receipt.bytes) / duration,
                "finalHost": receipt.responseURL?.host ?? "", "status": receipt.status!,
                "redirectCount": metrics.redirectCount, "transactions": transactions]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
            fflush(stdout)
            manager.cancelDownload(download)
        }
    }
}
