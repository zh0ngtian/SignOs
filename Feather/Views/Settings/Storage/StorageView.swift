import SwiftUI
import CoreData
import NimbleViews

struct StorageView: View {
    @State private var _sizes: [Category: Int64] = [:]
    @State private var _isCleaning = false
    @State private var _cleanedMessage: String?
    @State private var _showConfirmation = false
    @State private var _pendingAction = CleanupAction.superseded
    @State private var _confirmationMessage = ""

    @FetchRequest(entity: Signed.entity(),
                  sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
                  animation: .snappy)
    private var _signedApps: FetchedResults<Signed>

    @FetchRequest(entity: Imported.entity(),
                  sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
                  animation: .snappy)
    private var _importedApps: FetchedResults<Imported>

    enum Category: String, CaseIterable, Sendable {
        case archives = "Archives"
        case certificates = "Certificates"
        case installed = "Installed Apps"
        case imports = "Imported Apps"
    }

    private enum CleanupAction { case superseded, duplicates, archives }

    var body: some View {
        NBNavigationView(.localized("Storage")) {
            Form {
                NBSection(.localized("Usage")) {
                    ForEach(Category.allCases, id: \.self) { category in
                        HStack {
                            Label(String.localized(category.rawValue), systemImage: _icon(for: category))
                            Spacer()
                            Text(verbatim: (_sizes[category] ?? 0).formattedByteCount)
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(.localized("Total")).font(.body.weight(.semibold))
                        Spacer()
                        Text(verbatim: Category.allCases.reduce(Int64(0)) { $0 + (_sizes[$1] ?? 0) }.formattedByteCount)
                            .font(.footnote.weight(.bold).monospacedDigit())
                            .foregroundStyle(.tint)
                    }
                } footer: {
                    Text("旧副本按签名时间判断，保留最新可用签名包。重复导入仅清理已有同版本签名副本的包。")
                }

                NBSection(.localized("Cleanup")) {
                    Button { _requestCleanup(.superseded) } label: {
                        Label(.localized("Remove Superseded Copies"), systemImage: "arrow.3.trianglepath")
                    }
                    .accessibilityIdentifier("storage-clean-superseded")

                    Button { _requestCleanup(.duplicates) } label: {
                        Label(.localized("Remove Imported Duplicates"), systemImage: "square.stack.3d.up.slash")
                    }
                    .accessibilityIdentifier("storage-clean-duplicates")

                    Button { _requestCleanup(.archives) } label: {
                        Label(.localized("Clear Archives"), systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("storage-clear-archives")
                } footer: {
                    Text("保留禁用来源、正在处理及等待安装结果的应用包。清空归档仅删除导出的 IPA 文件，不删除应用包或证书。")
                }
                .disabled(_isCleaning)

                if _isCleaning {
                    Section { ProgressView("正在清理…") }
                }
                if let message = _cleanedMessage {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("storage-cleanup-result")
                    }
                }
            }
            .refreshable { await _refreshSizes() }
        }
        .task { await _refreshSizes() }
        .alert("确认清理", isPresented: $_showConfirmation) {
            Button("清理", role: .destructive) { _performCleanup(_pendingAction) }
            Button("取消", role: .cancel) { }
        } message: { Text(_confirmationMessage) }
    }

    private func _package(_ app: any AppInfoPresentable, protected: Set<String>) -> StorageCleanup.Package? {
        guard let uuid = app.uuid else { return nil }
        let jobs = AutoSignManager.shared.queue + (AutoSignManager.shared.currentJob.map { [$0] } ?? [])
        let busy = SourceAccessManager.shared.isInUse(uuid)
            || app.identifier.map { SourceAccessManager.shared.hasActiveApplication($0) } == true
            || jobs.contains { $0.appUUID == uuid || (app.identifier != nil && $0.appIdentifier == app.identifier) }
            || DownloadManager.shared.downloads.contains { download in
                download.targetAppUUID == uuid || download.sourceProvenance.map {
                    SourceSubscriptionIdentity.bundleIdentifier(from: $0.sourceAppIdentifier) == app.identifier
                } == true
            }
        let available = Storage.shared.getAppDirectory(for: app).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        return .init(uuid: uuid, identifier: app.identifier, version: app.version, date: app.date,
                     sourceVersionID: Storage.shared.sourceMetadata(for: app)?.sourceVersionID,
                     canRemove: AppOperations.isAllowed(app) && !busy && !protected.contains(uuid),
                     isAvailable: available, isSourceManaged: AppOperations.isSourceManaged(app))
    }

    private func _victims(for action: CleanupAction) -> [any AppInfoPresentable] {
        let protected = InstallPackageRetention.shared.protectedPackageUUIDs
        let signed = _signedApps.compactMap { _package($0, protected: protected) }
        switch action {
        case .superseded:
            let ids = Set(StorageCleanup.superseded(in: signed))
            return _signedApps.filter { $0.uuid.map(ids.contains) == true }.map { $0 as any AppInfoPresentable }
        case .duplicates:
            let imported = _importedApps.compactMap { _package($0, protected: protected) }
            let ids = Set(StorageCleanup.duplicates(imported: imported, signed: signed))
            return _importedApps.filter { $0.uuid.map(ids.contains) == true }.map { $0 as any AppInfoPresentable }
        case .archives: return []
        }
    }

    private func _requestCleanup(_ action: CleanupAction) {
        guard !_isCleaning else { return }
        _cleanedMessage = nil
        do {
            let count: Int
            if action == .archives {
                let directory = FileManager.default.archives
                count = FileManager.default.fileExists(atPath: directory.path)
                    ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count : 0
            } else { count = _victims(for: action).count }
            guard count > 0 else {
                _cleanedMessage = .localized("Nothing to clean up.")
                return
            }
            _pendingAction = action
            _confirmationMessage = action == .archives
                ? "将删除 \(count) 项导出归档。应用包和证书会保留。"
                : "将删除 \(count) 个应用包副本及其本地记录，不会卸载桌面应用。"
            _showConfirmation = true
        } catch { _cleanedMessage = "无法读取清理内容：\(error.localizedDescription)" }
    }

    private func _performCleanup(_ action: CleanupAction) {
        guard !_isCleaning else { return }
        _isCleaning = true
        _cleanedMessage = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            defer { _isCleaning = false }
            await Task.yield()
            do {
                let report: StorageCleanup.Report
                if action == .archives {
                    let directory = FileManager.default.archives
                    report = try await Task.detached(priority: .userInitiated) {
                        try StorageCleanup.clearArchives(at: directory)
                    }.value
                } else {
                    // Recompute after confirmation; source and task changes may protect a package.
                    report = StorageCleanup.remove(_victims(for: action)) {
                        try Storage.shared.deleteAppReportingErrors(for: $0)
                    }
                }
                if let error = report.failures.first {
                    _cleanedMessage = "已清理 \(report.removed) 项，\(report.failures.count) 项失败，可重试。\n\(error)"
                } else if report.removed == 0 {
                    _cleanedMessage = .localized("Nothing to clean up.")
                } else {
                    switch action {
                    case .superseded: _cleanedMessage = .localized("Removed %lld old copies.", arguments: report.removed)
                    case .duplicates: _cleanedMessage = .localized("Removed %lld imported duplicates.", arguments: report.removed)
                    case .archives: _cleanedMessage = .localized("Archives cleared.")
                    }
                }
            } catch { _cleanedMessage = "清理失败，可重试：\(error.localizedDescription)" }
            await _refreshSizes()
        }
    }

    private func _refreshSizes() async {
        let directories: [Category: URL] = [
            .archives: FileManager.default.archives, .certificates: FileManager.default.certificates,
            .installed: FileManager.default.signed, .imports: FileManager.default.unsigned
        ]
        _sizes = await Task.detached(priority: .utility) {
            directories.mapValues { StorageCleanup.directorySize(at: $0) }
        }.value
    }

    private func _icon(for category: Category) -> String {
        switch category {
        case .archives: return "archivebox"
        case .certificates: return "checkmark.seal"
        case .installed: return "square.stack.3d.up.fill"
        case .imports: return "tray.and.arrow.down.fill"
        }
    }
}
