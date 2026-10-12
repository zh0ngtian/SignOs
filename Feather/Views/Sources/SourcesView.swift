import SwiftUI
import CoreData

struct SourcesView: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @State private var isAdding = false
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
        }
        .task(id: Array(sources)) { await viewModel.fetchSources(sources) }
        .onReceive(viewModel.$sources) { _ in
            refreshDates = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]
        }
    }

    private func sourceCard(_ source: AltSource) -> some View {
        NavigationLink { SourceAppsView(object: [source], viewModel: viewModel) } label: {
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
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("浏览此软件源的全部应用")
        .padding(WSSpacing.lg)
        .background(WSRadius.continuous(WSRadius.xl).fill(WSSurface.card))
    }

    private func caption(_ source: AltSource) -> String {
        guard let repository = viewModel.sources[source] else {
            return viewModel.isFinished ? "无法刷新，下拉重试" : "正在刷新…"
        }
        let count = repository.apps.count
        let base = String.localized("%lld apps", arguments: count)
        guard let date = refreshDates[source.identifier ?? ""] else { return base }
        return base + " · " + date.formatted(.relative(presentation: .named))
    }
}

struct SourceManagementView: View {
    @ObservedObject var source: AltSource
    @ObservedObject var viewModel: SourcesViewModel
    var body: some View {
        Form { SourceManagementSection(source: source, viewModel: viewModel) }
            .navigationTitle("软件源设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

struct SourceManagementSection: View {
    @ObservedObject var source: AltSource
    @ObservedObject var viewModel: SourcesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false

    var body: some View {
        Section {
            Button("移除软件源", role: .destructive) { confirmsRemoval = true }
                .accessibilityIdentifier("source-remove")
        }
        .confirmationDialog("移除软件源？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("移除软件源", role: .destructive) { Storage.shared.deleteSource(for: source); dismiss() }
        }
    }
}
