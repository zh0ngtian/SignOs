import Foundation
import Combine
import UIKit
import BackgroundTasks
import UserNotifications

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    @Published private(set) var downloads: [Download] = []
    var manualDownloads: [Download] { downloads.filter { isManualDownload($0.id) } }

    private struct Context: Codable {
        let id: String
        let provenance: SourceAppProvenance?
        let targetAppUUID: String?
    }
    private let store: DownloadTransferStore?
    private let transport = HTTPRangeTransfer()
    private let limiter = DownloadTransferLimiter()
    private var engines: [UUID: SegmentedDownloadEngine] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var cleanups: [UUID: Task<Void, Never>] = [:]

    override init() {
        do { store = try .applicationStore() }
        catch { store = nil; AppLogger(category: "下载").error("下载缓存无法打开：\(error.localizedDescription)") }
        super.init()
        restore()
    }

    init(store: DownloadTransferStore) {
        self.store = store
        super.init()
        restore()
    }

    deinit { transport.invalidate() }

    private func restore() {
        guard let store else { return }
        let saved = store.load()
        for issue in saved.issues { AppLogger(category: "下载").error(issue) }
        for record in saved.records {
            do {
                if (try? String(contentsOf: store.directory(record.id).appendingPathComponent("imported"), encoding: .utf8)) == record.id.uuidString {
                    try store.remove(record.id)
                    continue
                }
                let context = try JSONDecoder().decode(Context.self, from: record.context)
                let download = makeDownload(record, context: context)
                download.state = record.phase == .requiresRestart ? .requiresRestart : .paused
                download.message = record.phase == .requiresRestart ? record.message : "已保留下载进度，点击继续。"
                let bytes = try (0..<record.partCount).reduce(Int64(0)) { $0 + (try store.size(store.part(record.id, $1))) }
                apply(.init(bytes: bytes, total: record.representation?.length ?? 0), to: download, updateState: false)
                downloads.append(download)
                engines[record.id] = makeEngine(record, store: store)
            } catch { AppLogger(category: "下载").error("下载记录恢复失败，缓存已保留：\(error.localizedDescription)") }
        }
    }

    private func makeDownload(_ record: DownloadCheckpoint, context: Context) -> Download {
        Download(id: context.id, url: record.url, sourceProvenance: context.provenance,
                 targetAppUUID: context.targetAppUUID, checkpointID: record.id, transferDirectory: store?.directory(record.id))
    }

    private func makeEngine(_ record: DownloadCheckpoint, store: DownloadTransferStore) -> SegmentedDownloadEngine {
        SegmentedDownloadEngine(record: record, store: store, transport: transport, limiter: limiter)
    }

    func startDownload(from url: URL, id: String = UUID().uuidString, sourceProvenance: SourceAppProvenance? = nil,
                       targetAppUUID: String? = nil) -> Download {
        if let existing = downloads.first(where: {
            $0.url == url && ($0.sourceProvenance != nil) == (sourceProvenance != nil)
                && $0.sourceProvenance?.sourceVersionID == sourceProvenance?.sourceVersionID && $0.targetAppUUID == targetAppUUID
        }) {
            resumeDownload(existing)
            return existing
        }
        let context = Context(id: id, provenance: sourceProvenance, targetAppUUID: targetAppUUID)
        do {
            guard let store else { throw DownloadTransferFailure.interrupted("下载缓存不可用，暂时无法开始下载。") }
            let record = DownloadCheckpoint(id: UUID(), url: url, context: try JSONEncoder().encode(context), fileName: url.lastPathComponent)
            let download = makeDownload(record, context: context)
            guard allowed(download) else { return download }
            try store.save(record)
            downloads.append(download)
            engines[record.id] = makeEngine(record, store: store)
            begin(download)
            return download
        } catch {
            AppLogger(category: "下载").error("无法创建下载：\(error.localizedDescription)")
            AppOperations.showError("无法保存下载记录，请检查剩余空间。")
            let failed = Download(id: id, url: url, sourceProvenance: sourceProvenance, targetAppUUID: targetAppUUID)
            failed.state = .failed
            return failed
        }
    }

    func startArchive(from url: URL, id: String = UUID().uuidString) -> Download {
        let download = Download(id: id, url: url, onlyArchiving: true)
        downloads.append(download)
        updateBackgroundAudio()
        return download
    }

    private func allowed(_ download: Download) -> Bool {
        guard let origin = download.sourceProvenance else { return true }
        let allowed = SourcePolicy.isEnabled(url: origin.sourceRepositoryURL, identifier: origin.sourceRepositoryIdentifier)
            && !SourcePolicy.isSubscriptionDeleted(url: origin.sourceRepositoryURL, identifier: origin.sourceRepositoryIdentifier, appIdentifier: origin.sourceAppIdentifier)
        if !allowed { AppOperations.showError("来源已禁用或订阅已删除，请先启用软件源。") }
        return allowed
    }

    func resumeDownload(_ download: Download) {
        guard download.canContinue, allowed(download) else { return }
        begin(download)
    }

    func pauseDownload(_ download: Download) {
        guard download.canPause, let id = download.checkpointID else { return }
        download.state = .pausing
        operations[id]?.cancel()
    }

    /// Invoked only after the user confirms discarding the previous byte ranges.
    func restartDownload(_ download: Download) {
        guard download.state == .requiresRestart, let id = download.checkpointID,
              operations[id] == nil, let engine = engines[id], let store, allowed(download) else { return }
        download.state = .pausing
        operations[id] = Task { [weak self] in
            let old = await engine.checkpoint()
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.downloads.contains(where: { $0 === download }) else { return }
                let context = try JSONDecoder().decode(Context.self, from: old.context)
                var replacement = DownloadCheckpoint(id: UUID(), url: old.url, context: old.context, fileName: old.fileName)
                replacement.mode = old.restartInSingleMode ? .single : .segmented
                try store.markDiscarded(id)
                try store.save(replacement)
                let next = self.makeDownload(replacement, context: context)
                self.operations[id] = nil
                self.engines[id] = nil
                self.downloads.removeAll { $0 === download }
                self.downloads.append(next)
                self.engines[replacement.id] = self.makeEngine(replacement, store: store)
                do { try store.remove(id) }
                catch { AppLogger(category: "下载").error("旧断点清理失败，将在重启时清理：\(error.localizedDescription)") }
                self.begin(next)
            } catch {
                self.operations[id] = nil
                download.state = .requiresRestart
                download.message = "无法重新创建下载，请检查剩余空间。"
                AppLogger(category: "下载").error("重新下载失败：\(error.localizedDescription)")
            }
        }
    }

    func cancelDownload(_ download: Download) {
        guard download.state != .importing else { return }
        if let id = download.checkpointID, let store {
            do { try store.markDiscarded(id) }
            catch { AppOperations.showError("取消状态无法保存，请稍后重试。"); return }
            let operation = operations.removeValue(forKey: id)
            operation?.cancel()
            engines[id] = nil
            cleanups[id] = Task { [weak self] in
                await operation?.value
                do { try store.remove(id) }
                catch { AppLogger(category: "下载").error("已取消下载的缓存清理失败：\(error.localizedDescription)") }
                self?.cleanups[id] = nil
            }
        }
        downloads.removeAll { $0 === download }
        removeProgressNotification(download)
        stopBackgroundTask(download, success: false)
        updateBackgroundAudio()
    }

    private func begin(_ download: Download) {
        guard let id = download.checkpointID, let engine = engines[id], operations[id] == nil else { return }
        download.state = .checking
        download.message = nil
        startBackgroundTask(download)
        AppLogger(category: "下载").info("开始或继续下载：\(download.url.absoluteString)")
        operations[id] = Task { [weak self] in
            do {
                let result = try await engine.run { [weak self] value in await self?.update(value, id: id) }
                try Task.checkCancellation()
                guard let self, self.downloads.contains(where: { $0 === download }) else { return }
                self.operations[id] = nil
                download.state = .importing
                download.progress = 1
                try self.handlePachageFile(url: result.file, dl: download)
            } catch {
                let record = await engine.checkpoint()
                let saved = try? await engine.savedProgress()
                guard let self, self.downloads.contains(where: { $0 === download }) else { return }
                self.operations[id] = nil
                if let saved { self.apply(saved, to: download, updateState: false) }
                download.state = record.phase == .requiresRestart ? .requiresRestart : (record.phase == .failed ? .failed : .paused)
                download.message = record.message
                self.removeProgressNotification(download)
                self.stopBackgroundTask(download, success: false)
                self.updateBackgroundAudio()
                if !(error is CancellationError) { AppLogger(category: "下载").error("下载已保留：\(error.localizedDescription)") }
            }
        }
        updateBackgroundAudio()
    }

    private func update(_ progress: SegmentedDownloadEngine.Progress, id: UUID) {
        guard let download = downloads.first(where: { $0.checkpointID == id }), download.state != .pausing else { return }
        apply(progress, to: download)
        postProgressIfDue(download)
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress) }
        #endif
    }

    private func apply(_ value: SegmentedDownloadEngine.Progress, to download: Download, updateState: Bool = true) {
        download.bytesDownloaded = value.bytes
        download.totalBytes = value.total
        download.progress = value.total > 0 ? min(1, Double(value.bytes) / Double(value.total)) : 0
        if updateState { download.state = value.assembling ? .preparing : .downloading }
    }

    func handlePachageFile(url: URL, dl: Download) throws {
        dl.state = .importing
        FR.handlePackageFile(url, download: dl) { [weak self, weak dl] error in
            Task { @MainActor in
                guard let self, let dl else { return }
                self.removeProgressNotification(dl)
                if let error {
                    dl.state = .failed
                    dl.message = "导入失败，已保留下载文件，可点击重试。"
                    if dl.checkpointID == nil { self.downloads.removeAll { $0 === dl } }
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    AppLogger(category: "下载").error("导入下载文件失败：\(error.localizedDescription)")
                    self.stopBackgroundTask(dl, success: false)
                } else {
                    if let id = dl.checkpointID, let store = self.store {
                        do { try store.markDiscarded(id); try store.remove(id) }
                        catch { AppLogger(category: "下载").error("下载缓存清理失败：\(error.localizedDescription)") }
                        self.engines[id] = nil
                    }
                    self.downloads.removeAll { $0 === dl }
                    self.stopBackgroundTask(dl, success: true)
                    AppOperations.resumeDeferredUpdates()
                }
                self.updateBackgroundAudio()
            }
        }
    }

    func isManualDownload(_ string: String) -> Bool { string.contains("FeatherManualDownload") }
    func getDownload(by id: String) -> Download? { downloads.first { $0.id == id } }
    func getDownloadIndex(by id: String) -> Int? { downloads.firstIndex { $0.id == id } }

    private func updateBackgroundAudio() {
        #if !targetEnvironment(macCatalyst)
        if #unavailable(iOS 26.0) {
            if downloads.contains(where: \.isActive) { BackgroundAudioManager.shared.start() }
            else { BackgroundAudioManager.shared.stop() }
        }
        #endif
    }
    private func startBackgroundTask(_ download: Download) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { BackgroundTaskManager.shared.startTask(for: download.id, filename: download.fileName) }
        #endif
    }
    private func stopBackgroundTask(_ download: Download, success: Bool) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { BackgroundTaskManager.shared.stopTask(for: download.id, success: success) }
        #endif
    }
    private func postProgressIfDue(_ download: Download) {
        guard UserDefaults.standard.object(forKey: "SignOs.notificationsEnabled") as? Bool ?? true,
              download.progress - download.lastNotificationProgress >= 0.1 else { return }
        download.lastNotificationProgress = download.progress
        let content = UNMutableNotificationContent()
        content.title = download.fileName
        content.body = .localized("Downloading… %lld%%", arguments: Int(download.overallProgress * 100))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "signos.download.\(download.id)", content: content, trigger: nil))
    }
    private func removeProgressNotification(_ download: Download) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["signos.download.\(download.id)"])
    }
}
