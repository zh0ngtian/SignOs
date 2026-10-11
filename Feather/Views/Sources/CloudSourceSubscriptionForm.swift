import SwiftUI

struct CloudSourceSubscriptionForm: View {
    let store: CloudSourceStore
    var entry: CloudSourceEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var config = CloudSourceConfiguration()
    @State private var candidates: [CloudSourceCandidate] = []
    @State private var selectedCandidate: Int64?
    @State private var isDiscovering = false
    @State private var discoveryError: String?

    var body: some View {
        Form {
            Section {
                Picker("订阅类型", selection: $config.kind) { Text("GitHub Release").tag("github"); Text("直接 IPA 地址").tag("url") }
            }
            if config.kind == "github" {
                Section("GitHub 仓库") {
                    TextField("https://github.com/owner/repo", text: binding(\.repository))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("cloud-source-repository")
                    TextField("tag 前缀（可选）", text: binding(\.tagPrefix)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("包含预发布版本", isOn: Binding(get: { config.includePrereleases ?? false }, set: { config.includePrereleases = $0 }))
                    Button("读取 Release 附件") { Task { await discover() } }.disabled(isDiscovering)
                }
                if !candidates.isEmpty {
                    Section("选择 IPA") {
                        ForEach(candidates) { candidate in
                            CloudSourceCandidateRow(candidate: candidate, selected: selectedCandidate == candidate.id) { select(candidate) }
                        }
                    }
                }
                Section {
                    TextField("例如 CodexMobile-*.ipa", text: binding(\.assetPattern)).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("后续版本匹配规则") } footer: {
                    Text("* 可匹配版本号等变化的文字。后续匹配到多个 IPA 时会提示选择，并保留原版本。")
                }
            } else {
                Section {
                    TextField("https://example.com/app.ipa", text: binding(\.url), axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("cloud-source-ipa-url")
                } header: { Text("IPA 下载地址") } footer: { Text("使用可直接下载的 HTTPS 地址。添加后自动读取应用信息，失败时展示具体原因。") }
            }
            if entry != nil { Section { Toggle("暂停自动同步", isOn: $config.paused) } }
            if isDiscovering { Section { ProgressView("正在读取 Release…") } }
            if let error = discoveryError ?? store.errorMessage { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
        }
        .navigationTitle(entry == nil ? "添加订阅" : "订阅设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("解析") { Task { if await store.save(config: config, entryID: entry?.id) { dismiss() } } }
                    .disabled(store.isBusy || isDiscovering || !canSave)
                    .accessibilityIdentifier("cloud-source-parse")
            }
        }
        .task { if let entry { config = entry.config } }
        .onChange(of: config.repository) { candidates = []; selectedCandidate = nil }
        .onChange(of: config.tagPrefix) { candidates = []; selectedCandidate = nil }
        .onChange(of: config.includePrereleases) { candidates = []; selectedCandidate = nil }
    }

    private var canSave: Bool {
        if config.kind == "url" { return !(config.url ?? "").isEmpty }
        return !(config.repository ?? "").isEmpty && (entry != nil || selectedCandidate != nil) && !(config.assetPattern ?? "").isEmpty
    }

    private func binding(_ key: WritableKeyPath<CloudSourceConfiguration, String?>) -> Binding<String> {
        Binding(get: { config[keyPath: key] ?? "" }, set: { config[keyPath: key] = $0 })
    }

    private func discover() async {
        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }
        do {
            candidates = try await store.discover(config: config)
            if candidates.count == 1, let candidate = candidates.first { select(candidate) }
        } catch { discoveryError = error.localizedDescription }
    }

    private func select(_ candidate: CloudSourceCandidate) {
        selectedCandidate = candidate.id
        config.assetPattern = candidate.name.replacingOccurrences(of: "v?[0-9]+(?:\\.[0-9]+){1,3}", with: "*", options: .regularExpression)
    }
}

struct CloudSourceEntryView: View {
    let store: CloudSourceStore
    let entryID: String
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var isDeleting = false

    private var entry: CloudSourceEntry? { store.snapshot?.entries.first { $0.id == entryID } }

    var body: some View {
        Form {
            if let entry {
                Section("同步状态") {
                    HStack { Text(entry.statusText); if entry.isWorking { Spacer(); ProgressView() } }
                    if let error = entry.error {
                        Label(error.message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error.code).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("重试同步") { Task { await store.synchronize(entry) } }.disabled(entry.isWorking || store.isBusy || entry.config.paused)
                }
                if let current = entry.current {
                    Section(entry.published ? "已发布的应用" : "解析结果") {
                        LabeledContent("应用名称", value: current.metadata.name)
                        LabeledContent("Bundle ID", value: current.metadata.bundleIdentifier)
                        LabeledContent("版本", value: current.metadata.version)
                        if let build = current.metadata.buildVersion { LabeledContent("构建号", value: build) }
                        if let minimum = current.metadata.minOSVersion { LabeledContent("最低 iOS", value: minimum) }
                        LabeledContent("IPA 大小", value: ByteCountFormatter.string(fromByteCount: current.inspection.fullBytes, countStyle: .file))
                        if let url = URL(string: current.downloadURL) { ShareLink(item: url) { Label("原始 IPA 下载地址", systemImage: "link") } }
                    }
                    if !entry.published && entry.status == "ready" {
                        Section { Button("确认添加到软件源") { Task { await store.confirm(entry) } }.disabled(store.isBusy) }
                    }
                }
                Section("订阅规则") {
                    Text(entry.config.repository ?? entry.config.url ?? "").textSelection(.enabled)
                    if let pattern = entry.config.assetPattern { LabeledContent("IPA 匹配", value: pattern) }
                    Button("修改订阅") { isEditing = true }
                }
                Section { Button("删除订阅", role: .destructive) { isDeleting = true } }
            }
            if let error = store.errorMessage { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle(entry?.title ?? "订阅")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditing) { if let entry { NavigationStack { CloudSourceSubscriptionForm(store: store, entry: entry) } } }
        .confirmationDialog("删除订阅及其公开应用记录？", isPresented: $isDeleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let entry { Task { await store.delete(entry); if store.errorMessage == nil { dismiss() } } } }
        }
        .refreshable { await store.refresh() }
    }
}

private struct CloudSourceCandidateRow: View {
    let candidate: CloudSourceCandidate
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.name).foregroundStyle(.primary)
                    Text(candidate.caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill") }
            }
        }
    }
}
