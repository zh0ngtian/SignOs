import SwiftUI
import CoreData

struct SourcesView: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @State private var isAdding = false
    @State private var syncing: Set<NSManagedObjectID> = []
    @State private var syncError: String?
    @State private var refreshDates = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)], animation: .snappy)
    private var sources: FetchedResults<AltSource>

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WSSpacing.sectionGap) {
                    WSHeroHeader(eyebrow: "SignOs", title: .localized("Sources"))
                    VStack(spacing: WSSpacing.md) {
                        ForEach(sources) { source in sourceCard(source) }
                    }
                    Button { isAdding = true } label: {
                        Label("Add Source", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(WSSpacing.lg)
                            .background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.cardFaded))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, WSSpacing.screenPadding)
                .padding(.top, WSSpacing.xs)
                .padding(.bottom, WSSpacing.xxl + 8)
            }
            .background(WSSurface.background)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await viewModel.fetchSources(sources, refresh: true) }
            .sheet(isPresented: $isAdding) { SourcesAddView() }
            .alert("同步失败", isPresented: Binding(get: { syncError != nil }, set: { if !$0 { syncError = nil } })) {
                Button("好", role: .cancel) { syncError = nil }
            } message: { Text(syncError ?? "") }
        }
        .task(id: Array(sources)) { await viewModel.fetchSources(sources) }
        .onReceive(viewModel.$sources) { _ in
            refreshDates = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]
        }
    }

    private func sourceCard(_ source: AltSource) -> some View {
        HStack(spacing: WSSpacing.sm) {
            NavigationLink {
                if let endpoint = CloudSourceEndpoint.managementURL(for: source.sourceURL) {
                    CloudSourceManagerView(source: source, managementAddress: endpoint.absoluteString)
                } else {
                    SourceManagementView(source: source, viewModel: viewModel)
                }
            } label: {
                HStack(spacing: WSSpacing.lg) {
                    WSAppIcon(url: source.iconURL, size: 48, cornerRadius: 11)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name ?? .localized("Source"))
                            .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        Text(caption(source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("打开软件源管理页面")

            Button { Task { await synchronize(source) } } label: {
                Group {
                    if syncing.contains(source.objectID) { ProgressView() }
                    else { Text("同步").font(.subheadline.weight(.semibold)) }
                }
                .frame(minWidth: 60, minHeight: 44)
                .background(Capsule().fill(WSSurface.input))
            }
            .buttonStyle(.borderless)
            .disabled(syncing.contains(source.objectID))
            .accessibilityLabel("同步 \(source.name ?? .localized("Source"))")
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(WSSpacing.lg)
        .background(WSRadius.continuous(WSRadius.xl).fill(WSSurface.card))
    }

    private func caption(_ source: AltSource) -> String {
        guard let repository = viewModel.sources[source] else {
            return viewModel.isFinished ? "无法刷新，点击同步重试" : "正在刷新…"
        }
        let count = repository.apps.count
        let base = count == 1 ? "1 app" : "\(count) apps"
        guard let date = refreshDates[source.identifier ?? ""] else { return base }
        return base + " · " + date.formatted(.relative(presentation: .named))
    }

    @MainActor
    private func synchronize(_ source: AltSource) async {
        guard syncing.insert(source.objectID).inserted else { return }
        defer { syncing.remove(source.objectID) }
        do {
            if let endpoint = CloudSourceEndpoint.managementURL(for: source.sourceURL),
               let token = CloudSourceCredentials.read(for: endpoint) {
                let store = CloudSourceStore()
                await store.connect(address: endpoint.absoluteString, token: token, expectedIdentifier: source.identifier)
                guard store.errorMessage == nil else { throw syncFailure(store.errorMessage!) }
                await store.synchronize()
                guard store.errorMessage == nil else { throw syncFailure(store.errorMessage!) }
                let deadline = Date().addingTimeInterval(60)
                while store.snapshot?.entries.contains(where: \.isWorking) == true {
                    guard Date() < deadline else { throw syncFailure("远端仍在解析应用，请稍后再次同步或进入管理页面查看进度。") }
                    try await Task.sleep(for: .seconds(2))
                    await store.refresh()
                    if let error = store.errorMessage { throw syncFailure(error) }
                }
                if let failure = store.snapshot?.entries.first(where: { $0.status == "failed" })?.error {
                    throw syncFailure(failure.message)
                }
            }
            try await viewModel.refreshSource(source)
        } catch { syncError = error.localizedDescription }
    }

    private func syncFailure(_ message: String) -> NSError {
        NSError(domain: "CloudSource", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct SourceManagementView: View {
    @ObservedObject var source: AltSource
    @ObservedObject var viewModel: SourcesViewModel
    var body: some View {
        Form { SourceManagementSection(source: source, viewModel: viewModel) }
            .navigationTitle(source.name ?? .localized("Source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

struct SourceManagementSection: View {
    @ObservedObject var source: AltSource
    @ObservedObject var viewModel: SourcesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false
    @State private var autoEnabled = true

    var body: some View {
        Section("本机订阅") {
            NavigationLink { SourceAppsView(object: [source], viewModel: viewModel) } label: {
                Label("浏览应用", systemImage: "square.grid.2x2")
            }
            if let url = source.sourceURL { ShareLink(item: url) { Label("分享软件源地址", systemImage: "link") } }
            Toggle("自动更新", isOn: $autoEnabled)
                .onChange(of: autoEnabled) { _, value in AutoUpdateManager.shared.setSourceAutoUpdate(value, for: source) }
            Button("移除软件源", role: .destructive) { confirmsRemoval = true }
        }
        .onAppear {
            autoEnabled = (UserDefaults.standard.dictionary(forKey: "SignOs.sourceAutoUpdate") as? [String: Bool])?[source.identifier ?? ""] ?? true
        }
        .confirmationDialog("移除软件源？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("移除软件源", role: .destructive) { Storage.shared.deleteSource(for: source); dismiss() }
        }
    }
}
