import SwiftUI
import AltSourceKit

struct CloudSourceManagerView: View {
    let source: AltSource
    let managementAddress: String?
    @ObservedObject private var sources = SourcesViewModel.shared
    @State private var store = CloudSourceStore()
    @State private var token = ""
    @State private var isAdding = false

    var body: some View {
        Form {
            localBundleIdentifierSection
            if let managementAddress {
                if let snapshot = store.snapshot {
                    Section {
                        LabeledContent("软件源", value: snapshot.settings.name)
                        Button { Task { await store.synchronize() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(store.isBusy)
                    } footer: {
                        Text("IPA 从原始地址直接下载。配置保存在远端，应用默认每小时检查一次更新。")
                    }
                    subscriptionSection(snapshot)
                } else {
                    Section {
                        LabeledContent("服务 HTTPS 地址") { Text(managementAddress).font(.caption).textSelection(.enabled) }
                        SecureField("管理 Token", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("cloud-source-token")
                        Button("连接") { Task { await store.connect(address: managementAddress, token: token, expectedIdentifier: source.identifier) } }
                            .disabled(store.isBusy || token.isEmpty)
                            .accessibilityIdentifier("cloud-source-connect")
                    } header: { Text("连接远端软件源") } footer: {
                        Text("输入管理 Token 后，可以添加订阅和查看同步结果。")
                    }
                }
            }
            SourceManagementSection(source: source, viewModel: SourcesViewModel.shared)
            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled) }
            }
            if store.isBusy { Section { ProgressView("正在连接软件源…") } }
        }
        .navigationTitle("软件源设置")
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            try? await sources.refreshSource(source)
            if store.snapshot != nil { await store.refresh() }
        }
        .sheet(isPresented: $isAdding) { NavigationStack { CloudSourceSubscriptionForm(store: store) } }
        .task(id: managementAddress) {
            guard let managementAddress else { return }
            store.onEntryDeleted = { [weak store] entry, url, identifier in
                if let url {
                    let bundle = entry.current?.metadata.bundleIdentifier ?? entry.history.first?.metadata.bundleIdentifier
                    let count = store?.snapshot?.entries.filter { ($0.current?.metadata.bundleIdentifier ?? $0.history.first?.metadata.bundleIdentifier) == bundle }.count ?? 0
                    SourceAccessManager.shared.deleteSubscription(url: url, identifier: identifier, bundle: bundle, subscriptionID: entry.id, allowLegacy: bundle != nil && count == 1)
                }
            }
            store.onBackupRestored = { url, identifier in
                if let url { SourceAccessManager.shared.clearDeletedSubscriptions(url: url, identifier: identifier) }
            }
            if let endpoint = try? CloudSourceEndpoint.baseURL(managementAddress), let saved = CloudSourceCredentials.read(for: endpoint) {
                token = saved
                await store.connect(address: managementAddress, token: saved, expectedIdentifier: source.identifier)
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if store.snapshot?.entries.contains(where: \.isWorking) == true { await store.refresh() }
            }
        }
    }

    private var localApps: [ASRepository.App] {
        let apps = sources.sources[source]?.apps ?? []
        var seen = Set<String>()
        return apps.filter { app in app.id.map { seen.insert($0).inserted } ?? false }
            .sorted { $0.currentName.localizedStandardCompare($1.currentName) == .orderedAscending }
    }

    private var localBundleIdentifierSection: some View {
        Section {
            ForEach(localApps, id: \.id) { app in
                if let identifier = app.id {
                    NavigationLink {
                        ApplicationBundleIdentifierView(originalIdentifier: identifier)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.currentName)
                            Text(AppBundleIdentifierPreferences.shared.identifier(for: identifier))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("source.bundleIdentifier.\(identifier)")
                }
            }
            if localApps.isEmpty {
                Text("加载软件源应用后即可配置 Bundle ID，请下拉刷新。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("本机 Bundle ID")
        } footer: {
            Text("无需管理 Token。默认使用原始 ID，修改仅保存在本机，不会更改软件源。相同应用的不同版本和软件源共用此配置。")
        }
    }

    private func subscriptionSection(_ snapshot: CloudSourceSnapshot) -> some View {
        Section("订阅项目") {
            if snapshot.entries.isEmpty { Text("添加 GitHub 仓库或 IPA 下载地址。").foregroundStyle(.secondary) }
            ForEach(snapshot.entries) { entry in
                NavigationLink(destination: CloudSourceEntryView(store: store, entryID: entry.id)) {
                    CloudSourceEntryRow(entry: entry, endpoint: store.endpoint)
                }
            }
            Button { isAdding = true } label: { Label("添加订阅", systemImage: "plus.circle.fill") }
        }
    }

}

private struct CloudSourceEntryRow: View {
    let entry: CloudSourceEntry
    let endpoint: URL?
    var body: some View {
        HStack(spacing: 12) {
            WSAppIcon(url: entry.iconURL(relativeTo: endpoint), size: 48, cornerRadius: 11)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title).font(.headline).lineLimit(2)
                Text(entry.versionText).font(.subheadline).foregroundStyle(.secondary)
                if let pattern = entry.config.assetPattern, !pattern.isEmpty {
                    Text(pattern).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(entry.statusText).font(.caption).foregroundStyle(entry.error == nil ? Color.secondary : Color.orange)
                if let error = entry.error { Text(error.message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if entry.isWorking { ProgressView().accessibilityLabel("正在同步") }
        }
        .padding(.vertical, 3)
    }
}
