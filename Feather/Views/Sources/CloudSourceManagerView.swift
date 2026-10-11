import SwiftUI
import UniformTypeIdentifiers

struct CloudSourceBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct CloudSourceManagerView: View {
    @AppStorage("SignOs.cloudSourceAddress") private var address = CloudSourceEndpoint.defaultURL
    @State private var store = CloudSourceStore()
    @State private var token = ""
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var backup = CloudSourceBackupDocument(data: Data())
    @State private var restoreData: Data?
    @State private var isRestoring = false
    @State private var showsSettings = false
    @State private var newToken: String?
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
                Section("配置备份") {
                    Button("导出配置", action: exportConfiguration)
                    Button("从文件恢复配置") { isImporting = true }
                }
                Section {
                    Button("轮换管理 Token") { Task { newToken = await store.rotateToken() } }
                    Button("断开管理连接", role: .destructive) { store.disconnect(); token = "" }
                } header: { Text("管理访问") } footer: {
                    Text("管理 Token 保存在钥匙串。断开管理连接后，已订阅的软件源仍可读取。")
                }
            } else {
                Section {
                    TextField("服务 HTTPS 地址", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("cloud-source-address")
                    SecureField("管理 Token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("cloud-source-token")
                    Button("连接") { Task { await store.connect(address: address, token: token) } }
                        .disabled(store.isBusy || token.isEmpty)
                        .accessibilityIdentifier("cloud-source-connect")
                } header: { Text("连接远端软件源") } footer: {
                    Text("输入管理 Token 后，可以添加订阅和查看同步结果。")
                }
            }
            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled) }
            }
            if store.isBusy { Section { ProgressView("正在连接软件源…") } }
        }
        .navigationTitle("远端软件源")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $isAdding) { NavigationStack { CloudSourceSubscriptionForm(store: store) } }
        .sheet(isPresented: $showsSettings) { NavigationStack { CloudSourceSettingsView(store: store) } }
        .fileExporter(isPresented: $isExporting, document: backup, contentType: .json, defaultFilename: "SignOs-source-backup") { result in
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                restoreData = data
                isRestoring = true
            } catch { store.errorMessage = error.localizedDescription }
        }
        .confirmationDialog("恢复会替换远端订阅配置，并重新解析应用", isPresented: $isRestoring, titleVisibility: .visible) {
            Button("恢复配置", role: .destructive) { if let restoreData { Task { await store.restoreBackup(restoreData); self.restoreData = nil } } }
        }
        .alert("已订阅软件源", isPresented: $sourceAdded) { Button("好", role: .cancel) {} }
        .sheet(item: Binding(get: { newToken.map(TokenDisplay.init) }, set: { newToken = $0?.id })) { item in
            NavigationStack {
                Form {
                    Section("新的管理 Token") { Text(item.id).textSelection(.enabled); ShareLink(item: item.id) { Label("保存 Token", systemImage: "square.and.arrow.up") } }
                    Section { Text("本设备已保存新 Token，旧 Token 已失效。其他设备需使用新 Token 连接。") }
                }
                .navigationTitle("管理 Token")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { newToken = nil } } }
            }
        }
        .task {
            if let endpoint = try? CloudSourceEndpoint.baseURL(address), let saved = CloudSourceCredentials.read(for: endpoint) {
                token = saved
                await store.connect(address: address, token: saved)
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
                    CloudSourceEntryRow(entry: entry)
                }
            }
            Button { isAdding = true } label: { Label("添加订阅", systemImage: "plus.circle.fill") }
        }
    }

    private struct TokenDisplay: Identifiable { let id: String }

    private func exportConfiguration() {
        Task {
            do {
                let data = try await store.exportBackup()
                backup = CloudSourceBackupDocument(data: data)
                isExporting = true
            } catch { store.errorMessage = error.localizedDescription }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.title).font(.headline).lineLimit(1)
                Spacer()
                if entry.isWorking { ProgressView() }
            }
            Text(entry.statusText).font(.caption).foregroundStyle(entry.error == nil ? Color.secondary : Color.orange)
            if let error = entry.error { Text(error.message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
    }
}
