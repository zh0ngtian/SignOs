import SwiftUI

struct CloudSourceSubscriptionForm: View {
    let store: CloudSourceStore
    var entry: CloudSourceEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var config = CloudSourceConfiguration()
    @State private var candidates: [CloudSourceCandidate] = []
    @State private var selectedCandidates: Set<Int64> = []
    @State private var assetPatterns: [Int64: String] = [:]
    @State private var addedCandidates: Set<Int64> = []
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
                    Section {
                        ForEach(candidates) { candidate in
                            CloudSourceCandidateRow(candidate: candidate, selected: selectedCandidates.contains(candidate.id), added: addedCandidates.contains(candidate.id)) { select(candidate) }
                                .disabled(addedCandidates.contains(candidate.id))
                        }
                    } header: { Text(entry == nil ? "选择 IPA（可多选）" : "选择 IPA") } footer: {
                        if entry == nil { Text("已选择 \(selectedCandidates.count) 个 IPA，每个 IPA 将建立独立订阅，分别同步版本和历史。") }
                    }
                }
                if entry != nil {
                    Section {
                        TextField("例如 CodexMobile-*.ipa", text: binding(\.assetPattern)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("后续版本匹配规则") } footer: { Text(ruleHelp) }
                } else {
                    ForEach(selectedAssets) { candidate in
                        Section {
                            TextField("IPA 匹配规则", text: patternBinding(candidate), axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("cloud-source-pattern-\(candidate.id)")
                        } header: { Text(candidate.name) } footer: {
                            if let error = validationMessage(for: candidate) {
                                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            } else { Text(ruleHelp) }
                        }
                    }
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
            if store.isBusy { Section { ProgressView("正在添加订阅…") } }
            if let error = discoveryError ?? store.errorMessage { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
        }
        .disabled(store.isBusy || isDiscovering)
        .interactiveDismissDisabled(store.isBusy)
        .navigationTitle(entry == nil ? "添加订阅" : "订阅设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.isBusy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(entry == nil && selectedCandidates.count > 1 ? "解析 \(selectedCandidates.count) 个 IPA" : "解析") { Task { await save() } }
                    .disabled(store.isBusy || isDiscovering || !canSave)
                    .accessibilityIdentifier("cloud-source-parse")
            }
        }
        .task { if let entry { config = entry.config } }
        .onChange(of: config.kind) { clearCandidates() }
        .onChange(of: config.repository) { clearCandidates() }
        .onChange(of: config.tagPrefix) { clearCandidates() }
        .onChange(of: config.includePrereleases) { clearCandidates() }
    }

    private let ruleHelp = "* 可匹配版本号等变化的文字。每条规则应只匹配一个 IPA；后续出现多个匹配时会保留原版本并提示调整。"
    private var selectedAssets: [CloudSourceCandidate] { candidates.filter { selectedCandidates.contains($0.id) } }

    private var canSave: Bool {
        if config.kind == "url" { return !(config.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !(config.repository ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if entry != nil { return !(config.assetPattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !selectedAssets.isEmpty && selectedAssets.allSatisfy { validationMessage(for: $0) == nil }
    }

    private func binding(_ key: WritableKeyPath<CloudSourceConfiguration, String?>) -> Binding<String> {
        Binding(get: { config[keyPath: key] ?? "" }, set: { config[keyPath: key] = $0 })
    }

    private func discover() async {
        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }
        do {
            var discoveryConfig = config
            discoveryConfig.assetPattern = nil
            let discovered = try await store.discover(config: discoveryConfig)
            clearCandidates()
            candidates = discovered
            if candidates.count == 1, let candidate = candidates.first { select(candidate) }
        } catch { discoveryError = error.localizedDescription }
    }

    private func select(_ candidate: CloudSourceCandidate) {
        let pattern = CloudSourceAssetRule.suggestedPattern(for: candidate.name, candidateNames: candidates.map(\.name))
        if entry != nil {
            selectedCandidates = [candidate.id]
            config.assetPattern = pattern
        } else if selectedCandidates.contains(candidate.id) {
            selectedCandidates.remove(candidate.id)
        } else {
            selectedCandidates.insert(candidate.id)
            if assetPatterns[candidate.id] == nil { assetPatterns[candidate.id] = pattern }
        }
    }

    private func patternBinding(_ candidate: CloudSourceCandidate) -> Binding<String> {
        Binding(get: { assetPatterns[candidate.id] ?? "" }, set: { assetPatterns[candidate.id] = $0 })
    }

    private func validationMessage(for candidate: CloudSourceCandidate) -> String? {
        CloudSourceAssetRule.validationMessage(pattern: assetPatterns[candidate.id] ?? "", selectedName: candidate.name, candidateNames: candidates.map(\.name))
    }

    private func clearCandidates() {
        candidates = []
        selectedCandidates = []
        assetPatterns = [:]
        addedCandidates = []
    }

    private func save() async {
        discoveryError = nil
        if entry != nil || config.kind == "url" {
            if await store.save(config: config, entryID: entry?.id) { dismiss() }
            return
        }
        let assets = selectedAssets
        let configurations = assets.map { candidate in
            var subscription = config
            subscription.assetPattern = (assetPatterns[candidate.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return subscription
        }
        let savedCount = await store.save(configurations: configurations)
        for candidate in assets.prefix(savedCount) {
            selectedCandidates.remove(candidate.id)
            addedCandidates.insert(candidate.id)
        }
        if savedCount == assets.count { dismiss() }
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
    let added: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.name).foregroundStyle(.primary)
                    Text(candidate.caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if added { Text("已添加").font(.caption).foregroundStyle(.secondary) }
                Image(systemName: selected || added ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("cloud-source-candidate-\(candidate.id)")
        .accessibilityValue(added ? "已添加" : selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected || added ? .isSelected : [])
    }
}
