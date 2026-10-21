import SwiftUI
import CoreData
import NimbleViews

struct CertificateReplacementRequest: Identifiable {
    let id = UUID()
    let apps: [any AppInfoPresentable]
}

struct ApplicationDetailView: View {
    let identifier: String
    let packageUUID: String?
    @ObservedObject private var updates = UpdateManager.shared
    @ObservedObject private var signer = AutoSignManager.shared
    @ObservedObject private var access = SourceAccessManager.shared
    @State private var signing: AnyApp?
    @State private var installing: AnyApp?
    @State private var replacement: CertificateReplacementRequest?
    @State private var ruleRevision = 0
    @State private var deleting: AppPackageDeletion.Request?
    @FetchRequest(entity: Signed.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)], animation: .snappy)
    private var signed: FetchedResults<Signed>
    @FetchRequest(entity: Imported.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)], animation: .snappy)
    private var imported: FetchedResults<Imported>

    private var application: ManagedApplication? {
        let applications = AppInventory.applications(signed.map { $0 as any AppInfoPresentable } + imported.map { $0 as any AppInfoPresentable })
        return applications.first { $0.id == identifier } ?? applications.first {
            $0.packages.contains { !$0.isSigned && ($0.uuid == packageUUID || $0.identifier == identifier) }
        }
    }
    private var packages: [any AppInfoPresentable] { application?.packages ?? [] }
    private var currentIdentifier: String { application?.id ?? identifier }
    private var alternatives: [AppUpdate] { updates.candidates[currentIdentifier] ?? [] }

    var body: some View {
        let identifier = currentIdentifier
        Form {
            if let application {
                Section {
                    HStack(spacing: 14) {
                        FRAppIconView(app: application.primary, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(application.primary.name ?? identifier).font(.headline)
                            Text("\(application.installed == nil ? "待安装" : "已安装") · \(application.primary.version ?? "未知版本")").foregroundStyle(.secondary)
                            Text(AppOperations.sourceName(application.primary)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(identifier).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                    if let app = application.installed {
                        Button("打开应用") { UIApplication.openApp(with: identifier) }
                        if let cert = Storage.shared.getCertificate(from: app) {
                            LabeledContent("当前证书", value: cert.nickname ?? "签名证书")
                            if let date = cert.expiration { LabeledContent("证书有效期", value: date.formatted(date: .abbreviated, time: .omitted)) }
                            if !AppOperations.isValid(cert) { Label("需重新签名", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                        }
                        Button("更换证书并重新签名") { replacement = CertificateReplacementRequest(apps: [app]) }.disabled(!AppOperations.isAllowed(app))
                    }
                    if !AppOperations.isAllowed(application.primary) {
                        Label(AppOperations.sourceStatus(application.primary) ?? "来源不可用", systemImage: "pause.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = signer.installErrors[identifier] { Text(error).font(.footnote).foregroundStyle(.orange) }
                }
                Section("更新设置") {
                    Toggle("自动更新", isOn: Binding(get: { AutoUpdateManager.shared.isAutoUpdateEnabled(for: identifier) }, set: {
                        AutoUpdateManager.shared.setAutoUpdate($0, for: identifier); ruleRevision += 1
                    }))
                    Toggle("暂停版本更新", isOn: Binding(get: { updates.isHeld(for: identifier) }, set: {
                        updates.setHeld($0, for: identifier); ruleRevision += 1
                        Task { await AutoUpdateManager.shared.checkNow(notifyWhenClean: false) }
                    }))
                    if let skipped = updates.skippedVersion(for: identifier) {
                        Button("恢复已跳过的版本 \(skipped)") {
                            updates.clearSkip(for: identifier); ruleRevision += 1
                            Task { await AutoUpdateManager.shared.checkNow(notifyWhenClean: false) }
                        }
                    } else if let update = updates.update(for: application.primary) {
                        Button("跳过版本 \(update.remoteVersion)") {
                            updates.skip(version: update.remoteVersion, for: identifier)
                            updates.dismissUpdate(withLocalUUID: update.localUUID); ruleRevision += 1
                            AutoUpdateManager.shared.updateBadgeFromState()
                        }
                    }
                }
                Section {
                    ForEach(alternatives, id: \.sourceProvenance.sourceVersionID) { candidate in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.sourceProvenance.sourceRepositoryName ?? candidate.sourceURL.host ?? "软件源").font(.headline)
                                    Text("\(candidate.remoteVersion) · \(candidate.downloadURL.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("使用此版本") {
                                    updates.selectCandidate(candidate, for: identifier)
                                    AppOperations.update(candidate, allowReplacement: true)
                                }.buttonStyle(.borderless)
                            }
                            if let notes = candidate.whatsNew, !notes.isEmpty { Text(notes).font(.footnote).fixedSize(horizontal: false, vertical: true) }
                        }.padding(.vertical, 5)
                    }
                    Button("检查其他来源") { Task { await AutoUpdateManager.shared.checkNow(notifyWhenClean: false, syncManagedSources: true) } }
                } header: { Text("软件源版本") } footer: { Text("更新从启用源中选择较新版本。同版本优先当前来源，也可以主动选择其他来源或旧版本。") }
                Section {
                    ForEach(packages, id: \.uuid) { package in packageRow(package, current: application.primary.uuid == package.uuid) }
                } header: { Text("本地包与历史版本 · \(packages.count)") } footer: {
                    Text("所有本地包均可手动删除，包括软件源下载包。删除保留软件源订阅，不会卸载桌面应用；正在处理或待完成安装的包会保留供重试。")
                }
            } else {
                ContentUnavailableView("应用已移除", systemImage: "square.stack.3d.up")
            }
        }
        .navigationTitle(application?.primary.name ?? "应用详情")
        .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .sheet(item: $signing) { SigningView(app: $0.base) }
        .sheet(item: $installing) { InstallPreviewView(app: $0.base, isSharing: $0.archive).presentationDetents([.height(200)]).presentationDragIndicator(.visible) }
        .sheet(item: $replacement) { CertificateReplacementView(apps: $0.apps) }
        .packageDeletionConfirmation($deleting)
    }

    private func packageRow(_ app: any AppInfoPresentable, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(app.version ?? "未知版本") · \(app.isSigned ? "已签名" : "未签名")").font(.subheadline.weight(.semibold))
                Spacer()
                if current { Text("当前").font(.caption).foregroundStyle(.tint) }
            }
            Text(AppOperations.sourceName(app) + (AppOperations.sourceStatus(app).map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
            if let date = app.date { Text(date.formatted()).font(.caption2).foregroundStyle(.secondary) }
            if let cert = Storage.shared.getCertificate(from: app) { Text("证书：\(cert.nickname ?? "签名证书")").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 18) {
                NavigationLink("信息") { LibraryInfoView(app: app) }
                Menu("操作") {
                    Button("重新签名") { signing = AnyApp(base: app) }.disabled(!AppOperations.isAllowed(app))
                    if app.isSigned { Button("重新安装") { if let signed = app as? Signed { signer.enqueueInstall(app: signed) } }.disabled(!AppOperations.isAllowed(app)) }
                    else { Button("签名并安装") { signer.enqueue(app: app, force: true) }.disabled(!AppOperations.isAllowed(app)) }
                    Button("导出") { installing = AnyApp(base: app, archive: true) }
                    Button("克隆应用") { signer.cloneApp(app: app) }.disabled(!AppOperations.isAllowed(app))
                    Button("删除本地包", role: .destructive) { deleting = AppPackageDeletion.Request(package: app) }
                }
            }.font(.subheadline).buttonStyle(.borderless)
        }.padding(.vertical, 5)
    }
}

struct CertificateReplacementView: View {
    let apps: [any AppInfoPresentable]
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)])
    private var certificates: FetchedResults<CertificatePair>

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("为 \(apps.count) 个应用更换证书。将复用本地包，保留应用版本。")
                    Text("更改默认证书不会批量重签已有应用。此操作只影响这里列出的应用。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(apps, id: \.uuid) { Text($0.name ?? $0.identifier ?? "应用").font(.subheadline) }
                }
                Section("选择有效证书") {
                    ForEach(certificates) { certificate in
                        Button {
                            replace(with: certificate)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(certificate.nickname ?? "签名证书")
                                    if let date = certificate.expiration { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text("重新签名").font(.subheadline)
                            }
                        }.disabled(apps.isEmpty || !AppOperations.isValid(certificate))
                    }
                    if certificates.isEmpty { Text("请先在设置中导入证书。") }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("更换证书并重新签名").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func replace(with certificate: CertificatePair) {
        for app in apps {
            let options = AppOperations.signingOptions(for: app, base: .defaultOptions)
            if let issue = AppOperations.signingError(for: app, certificate: certificate, targetIdentifier: options.appIdentifier) {
                error = "\(app.name ?? "应用")：\(issue)"; return
            }
        }
        for app in apps {
            let options = AppOperations.signingOptions(for: app, base: .defaultOptions)
            AutoSignManager.shared.enqueue(app: app, reason: .renewal, certificate: certificate, options: options, force: true)
        }
        dismiss()
    }
}
