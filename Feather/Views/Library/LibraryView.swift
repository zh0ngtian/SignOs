import SwiftUI
import UIKit
import CoreData
import NimbleViews

struct LibraryView: View {
    @ObservedObject private var updates = UpdateManager.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var signer = AutoSignManager.shared
    @ObservedObject private var access = SourceAccessManager.shared
    @ObservedObject private var checker = AutoUpdateManager.shared
    @AppStorage("SignOs.applicationScope") private var scope = "all"
    @State private var search = ""
    @State private var importing = false
    @State private var importingURL = false
    @State private var urlText = ""
    @State private var replacement: CertificateReplacementRequest?
    @FetchRequest(entity: Signed.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)], animation: .snappy)
    private var signed: FetchedResults<Signed>
    @FetchRequest(entity: Imported.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)], animation: .snappy)
    private var imported: FetchedResults<Imported>

    private var applications: [ManagedApplication] {
        AppInventory.applications(signed.map { $0 as any AppInfoPresentable } + imported.map { $0 as any AppInfoPresentable },
            sourceUpdateDates: updates.sourceUpdateDates)
    }
    private var pending: Int { applications.filter { $0.installed == nil }.count }
    private var filtered: [ManagedApplication] {
        applications.filter {
            (scope != "updates" || updates.update(for: $0.primary) != nil) &&
            (scope != "pending" || $0.installed == nil) &&
            (search.isEmpty || ($0.primary.name ?? "").localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }
    }
    private var unknownDownloads: [Download] {
        downloads.downloads.filter { download in
            guard let origin = download.sourceProvenance else { return true }
            let bundle = SourceSubscriptionIdentity.bundleIdentifier(from: origin.sourceAppIdentifier)
            return !applications.contains { $0.id == bundle }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WSSpacing.sectionGap) {
                    WSHeroHeader(eyebrow: "\(applications.count) 个应用", title: "应用")
                    searchBar
                    if scope == "updates", !filtered.isEmpty {
                        HStack {
                            Text("可更新 \(filtered.count) 个应用").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            WSSearchCapsuleButton(title: "Update All") {
                                for app in filtered { if let update = updates.update(for: app.primary) { AppOperations.update(update) } }
                            }
                        }
                    }
                    LazyVStack(spacing: WSSpacing.md) {
                        ForEach(filtered) { application in
                            NavigationLink { ApplicationDetailView(identifier: application.id) } label: {
                                applicationCard(application)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if filtered.isEmpty {
                        WSEmptyState(icon: scope == "updates" ? "checkmark.seal" : "square.stack.3d.up",
                            title: emptyTitle,
                            message: search.isEmpty ? "导入应用，或从软件源下载。下拉可检查更新。" : "没有匹配的应用。")
                    }
                    if !updates.checkIssues.isEmpty {
                        WSCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("检查结果", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
                                ForEach(updates.checkIssues, id: \.self) { Text(verbatim: $0).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    ForEach(unknownDownloads) { WSDownloadCard(download: $0) }
                    addApp
                    if applications.contains(where: { $0.installed != nil }) {
                        Button("批量更换证书并重新签名") { replacement = CertificateReplacementRequest(apps: applications.compactMap { $0.installed }.filter(AppOperations.isAllowed)) }
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(.horizontal, WSSpacing.screenPadding).padding(.top, 4).padding(.bottom, 28)
                .background { LibraryRefreshCaption().allowsHitTesting(false) }
            }
            .background(WSSurface.background)
            .toolbar(.hidden, for: .navigationBar)
            // The manager owns the check; refresh-task cancellation only affects this waiter.
            .refreshable { await AutoUpdateManager.shared.checkNow(notifyWhenClean: false, syncManagedSources: true) }
            .sheet(isPresented: $importing) {
                FileImporterRepresentableView(allowedContentTypes: [.ipa, .tipa], allowsMultipleSelection: true, onDocumentsPicked: { urls in
                    for url in urls {
                        let download = downloads.startArchive(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
                        try? downloads.handlePachageFile(url: url, dl: download)
                    }
                }).ignoresSafeArea()
            }
            .alert("从 URL 导入", isPresented: $importingURL) {
                TextField("URL", text: $urlText).textInputAutocapitalization(.never)
                Button("取消", role: .cancel) { urlText = "" }
                Button("导入") {
                    if let url = URL(string: urlText), ["http", "https"].contains(url.scheme) {
                        _ = downloads.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
                    }
                    urlText = ""
                }
            }
            .sheet(item: $replacement) { CertificateReplacementView(apps: $0.apps) }
            .task { access.cleanupDeletedSubscriptions() }
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "没有匹配的应用" }
        if scope == "pending" { return "暂无待安装应用" }
        guard scope == "updates" else { return "暂无应用" }
        if checker.isAutoChecking || updates.isChecking { return "正在检查更新" }
        if !updates.checkIssues.isEmpty { return "更新检查未完成" }
        if updates.lastCheckedDate == nil { return "尚未检查更新" }
        return "All Apps Up to Date"
    }

    private var searchBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清除搜索") }
            }
            .padding(12).background(WSRadius.continuous(12).fill(WSSurface.card))
            Picker("筛选应用", selection: $scope) {
                Text("全部").tag("all")
                Text("可更新 \(updates.updates.count)").tag("updates")
                Text("待安装 \(pending)").tag("pending")
            }.pickerStyle(.segmented).accessibilityIdentifier("applications-filter")
        }
    }

    private func applicationCard(_ application: ManagedApplication) -> some View {
        let app = application.primary
        let update = updates.update(for: app)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                FRAppIconView(app: app, size: 57)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name ?? application.id).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(application.installed == nil ? "待安装" : "已安装") · \(app.version ?? "未知版本")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(AppOperations.sourceName(app) + (AppOperations.sourceStatus(app).map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if let update {
                        Text("\(app.version ?? "") → \(update.remoteVersion) · \(update.sourceProvenance.sourceRepositoryName ?? "软件源")")
                            .font(.caption).foregroundStyle(Color.accentColor)
                        if cached(update) { Text("新版已下载").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let cert = Storage.shared.getCertificate(from: app), !AppOperations.isValid(cert) {
                        Label("需重新签名", systemImage: "signature").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                action(application, update: update)
            }
            if let error = signer.installErrors[application.id] { Text(error).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let download = download(for: application) { WSDownloadCard(download: download) }
            if scope == "updates", let update {
                UpdateReleaseNotesView(releases: update.releaseHistory,
                    sourceName: update.sourceProvenance.sourceRepositoryName ?? "软件源")
            }
        }
        .padding(WSSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
        .accessibilityIdentifier("application-\(application.id)")
    }

    @ViewBuilder private func action(_ application: ManagedApplication, update: AppUpdate?) -> some View {
        if let job = signer.currentJob, job.appIdentifier == application.id {
            VStack(spacing: 5) { ProgressView(); Text(signer.currentPhase).font(.caption2).foregroundStyle(.secondary) }
        } else if access.hasActiveApplication(application.id) {
            VStack(spacing: 5) { ProgressView(); Text("安装处理中").font(.caption2).foregroundStyle(.secondary) }
        } else if signer.queue.contains(where: { $0.appIdentifier == application.id }) {
            Text("等待处理").font(.caption).foregroundStyle(.secondary)
        } else if download(for: application) != nil {
            Text("下载中").font(.caption).foregroundStyle(.secondary)
        } else if let update {
            WSSearchCapsuleButton(title: signer.installErrors[application.id] == nil ? "Update" : "重试更新") { AppOperations.update(update) }
        } else if let installed = application.installed {
            if signer.installErrors[application.id] != nil, let signed = installed as? Signed, AppOperations.isAllowed(signed) {
                WSSearchCapsuleButton(title: "重试安装") { signer.enqueueInstall(app: signed) }
            } else if let cert = Storage.shared.getCertificate(from: installed), !AppOperations.isValid(cert), AppOperations.isAllowed(installed) {
                WSSearchCapsuleButton(title: "重新签名") { replacement = CertificateReplacementRequest(apps: [installed]) }
            } else {
                WSSearchCapsuleButton(title: "Open") { UIApplication.openApp(with: application.id) }
            }
        } else if AppOperations.isAllowed(application.primary) {
            WSSearchCapsuleButton(title: "Install") { signer.enqueue(app: application.primary, force: true) }
        } else {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private func cached(_ update: AppUpdate) -> Bool {
        UpdateManager.shared.downloadedApp(for: update, among: applications.flatMap(\.packages), isPackageAvailable: {
            guard let directory = Storage.shared.getAppDirectory(for: $0) else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("Info.plist").path)
        }) != nil
    }

    private func download(for application: ManagedApplication) -> Download? {
        downloads.downloads.first { download in
            application.packages.contains { $0.uuid == download.targetAppUUID } ||
            download.sourceProvenance.map { SourceSubscriptionIdentity.bundleIdentifier(from: $0.sourceAppIdentifier) == application.id } == true
        }
    }

    private var addApp: some View {
        Menu {
            Button("从文件导入") { importing = true }
            Button("从 URL 导入") { importingURL = true }
        } label: {
            Label("添加应用", systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(14)
                .background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.cardFaded))
        }
    }
}

/// Keep the caption with this screen's native pull-to-refresh indicator.
private struct LibraryRefreshCaption: UIViewRepresentable {
    func makeUIView(context: Context) -> CaptionView { CaptionView() }

    func updateUIView(_ uiView: CaptionView, context: Context) {
        uiView.setNeedsLayout()
    }

    final class CaptionView: UIView {
        private let captionLabel = UILabel()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // SwiftUI installs the refresh control after attaching the content.
            DispatchQueue.main.async { [weak self] in self?.applyCaption() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyCaption()
        }

        private func applyCaption() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView, let refreshControl = scrollView.refreshControl {
                    let font = UIFont.preferredFont(forTextStyle: .footnote)
                    // Reserve the native title's space. SwiftUI can hide that title
                    // during refresh, so render the caption in our own label.
                    let spacingTitle = NSAttributedString(string: " ", attributes: [.font: font])
                    if refreshControl.attributedTitle != spacingTitle {
                        refreshControl.attributedTitle = spacingTitle
                    }
                    captionLabel.font = font
                    if captionLabel.superview !== refreshControl {
                        captionLabel.removeFromSuperview()
                        captionLabel.text = "正在检查更新"
                        captionLabel.textColor = .secondaryLabel
                        captionLabel.adjustsFontForContentSizeCategory = true
                        captionLabel.translatesAutoresizingMaskIntoConstraints = false
                        refreshControl.addSubview(captionLabel)
                        NSLayoutConstraint.activate([
                            captionLabel.centerXAnchor.constraint(equalTo: refreshControl.centerXAnchor),
                            captionLabel.bottomAnchor.constraint(equalTo: refreshControl.bottomAnchor, constant: -8),
                            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: refreshControl.leadingAnchor, constant: 16),
                            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshControl.trailingAnchor, constant: -16)
                        ])
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
