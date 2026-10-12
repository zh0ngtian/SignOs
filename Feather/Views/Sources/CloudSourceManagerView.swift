import SwiftUI

struct CloudSourceManagerView: View {
    var source: AltSource? = nil
    var managementAddress: String? = nil
    private var effectiveAddress: String { managementAddress ?? address }
    @AppStorage("SignOs.cloudSourceAddress") private var address = CloudSourceEndpoint.defaultURL
    @State private var store = CloudSourceStore()
    @State private var token = ""
    @State private var isAdding = false
    @State private var showsSettings = false
    @State private var sourceAdded = false

    var body: some View {
        Form {
            if let snapshot = store.snapshot {
                Section {
                    LabeledContent("软件源", value: snapshot.settings.name)
                    if let sourceURL = store.sourceURL {
                        ShareLink(item: sourceURL) { Label("分享软件源地址", systemImage: "link") }
                        Button { subscribe(snapshot) } label: { Label("订阅到 SignOs", systemImage: "square.and.arrow.down") }
                    }
                    Button { Task { await store.synchronize() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(store.isBusy)
                    Button("软件源设置") { showsSettings = true }
                } footer: {
                    Text("IPA 从原始地址直接下载。配置保存在远端，应用默认每小时检查一次更新。")
                }
                subscriptionSection(snapshot)
            } else {
                Section {
                    if let managementAddress {
                        LabeledContent("服务 HTTPS 地址") { Text(managementAddress).font(.caption).textSelection(.enabled) }
                    } else {
                        TextField("服务 HTTPS 地址", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("cloud-source-address")
                    }
                    SecureField("管理 Token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("cloud-source-token")
                    Button("连接") { Task { await store.connect(address: effectiveAddress, token: token, expectedIdentifier: source?.identifier) } }
                        .disabled(store.isBusy || token.isEmpty)
                        .accessibilityIdentifier("cloud-source-connect")
                } header: { Text("连接远端软件源") } footer: {
                    Text("输入管理 Token 后，可以添加订阅和查看同步结果。")
                }
            }
            if let source { SourceManagementSection(source: source, viewModel: SourcesViewModel.shared) }
            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled) }
            }
            if store.isBusy { Section { ProgressView("正在连接软件源…") } }
        }
        .navigationTitle(source == nil ? "远端软件源" : "软件源设置")
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $isAdding) { NavigationStack { CloudSourceSubscriptionForm(store: store) } }
        .sheet(isPresented: $showsSettings) { NavigationStack { CloudSourceSettingsView(store: store) } }
        .alert("已订阅软件源", isPresented: $sourceAdded) { Button("好", role: .cancel) {} }
        .task {
            if let endpoint = try? CloudSourceEndpoint.baseURL(effectiveAddress), let saved = CloudSourceCredentials.read(for: endpoint) {
                token = saved
                await store.connect(address: effectiveAddress, token: saved, expectedIdentifier: source?.identifier)
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if store.snapshot?.entries.contains(where: \.isWorking) == true { await store.refresh() }
            }
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

    private func subscribe(_ snapshot: CloudSourceSnapshot) {
        guard let sourceURL = store.sourceURL else { return }
        if let existing = Storage.shared.getSources().first(where: { $0.identifier == snapshot.settings.identifier }) {
            existing.sourceURL = sourceURL
            existing.name = snapshot.settings.name
            existing.iconURL = store.endpoint?.appendingPathComponent("icon.png")
            Storage.shared.saveContext()
            SourcesViewModel.shared.sources.removeValue(forKey: existing)
            sourceAdded = true
        } else {
            Storage.shared.addSource(sourceURL, name: snapshot.settings.name, identifier: snapshot.settings.identifier, iconURL: store.endpoint?.appendingPathComponent("icon.png")) { error in
                if let error { store.errorMessage = error.localizedDescription } else { sourceAdded = true }
            }
        }
    }
}

private struct CloudSourceSettingsView: View {
    let store: CloudSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sourceDescription = ""

    var body: some View {
        Form {
            Section("软件源信息") { TextField("名称", text: $name); TextField("简介", text: $sourceDescription, axis: .vertical) }
        }
        .navigationTitle("软件源设置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await store.updateSettings(name: name, description: sourceDescription); if store.errorMessage == nil { dismiss() } } }.disabled(name.isEmpty || store.isBusy) }
        }
        .task { name = store.snapshot?.settings.name ?? ""; sourceDescription = store.snapshot?.settings.description ?? "" }
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
