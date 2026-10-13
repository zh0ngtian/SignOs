import SwiftUI
import Combine
import UIKit

struct LogsView: View {
    @State private var entries: [AppLogEntry] = []
    @State private var query = ""
    @State private var level: AppLogEntry.Level?
    @State private var persistenceError: String?
    @State private var actionError: String?
    @State private var isWorking = false
    @State private var isConfirmingClear = false
    @State private var shareFile: LogShareFile?
    @State private var exportDirectory: URL?
    @State private var exportTask: Task<Void, Never>?

    private var filtered: [AppLogEntry] { AppLogEntry.filtered(entries, query: query, level: level) }

    var body: some View {
        List {
            Section {
                Picker("日志级别", selection: $level) {
                    Text("全部级别").tag(AppLogEntry.Level?.none)
                    ForEach(AppLogEntry.Level.allCases, id: \.self) { level in
                        Text(level.title).tag(Optional(level))
                    }
                }
                .accessibilityIdentifier("logs-level")
                if !query.isEmpty {
                    Button(action: export) {
                        Label("导出搜索结果", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("logs-export-search")
                    .disabled(isWorking || filtered.isEmpty)
                }
            } footer: {
                Text("日志仅保存在本机，最多保留 1000 条或 2 MiB。导出包含当前搜索和筛选结果。")
            }

            if let persistenceError {
                Section {
                    Label(persistenceError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                if filtered.isEmpty {
                    ContentUnavailableView(entries.isEmpty ? "暂无日志" : "没有匹配的日志",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(entries.isEmpty ? "启动、下载、导入和签名记录会显示在这里。" : "尝试其他关键词或日志级别。"))
                } else {
                    ForEach(filtered) { entry in
                        NavigationLink {
                            LogDetailView(entry: entry)
                        } label: {
                            LogRowView(entry: entry)
                        }
                    }
                }
            } header: {
                Text("\(filtered.count) 条记录 · 最新在前")
            }
        }
        .navigationTitle("日志")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索内容、分类或级别")
        .refreshable { await refresh() }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: AppLogStore.didChange)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)) { _ in
                Task { await refresh() }
            }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: export) {
                    if isWorking { ProgressView() }
                    else { Label("导出日志", systemImage: "square.and.arrow.up") }
                }
                .accessibilityIdentifier("logs-export")
                .disabled(isWorking || filtered.isEmpty)

                Menu {
                    Button("清空日志", systemImage: "trash", role: .destructive) { isConfirmingClear = true }
                        .disabled(isWorking || entries.isEmpty)
                } label: {
                    Label("更多操作", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("logs-more")
            }
        }
        .confirmationDialog("清空日志？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                Task {
                    isWorking = true
                    defer { isWorking = false }
                    do { try await AppLogStore.shared.clear(); await refresh() }
                    catch { actionError = "清空失败：\(error.localizedDescription)" }
                }
            }
        } message: {
            Text("将删除本机的全部诊断日志，包括筛选之外的记录。活动页和应用文件不受影响。")
        }
        .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .sheet(item: $shareFile, onDismiss: removeExport) { file in
            LogShareSheet(url: file.url)
                .presentationDetents([.medium, .large])
        }
        .onDisappear {
            if shareFile == nil {
                exportTask?.cancel()
                removeExport()
            }
        }
    }

    @MainActor
    private func refresh() async {
        let snapshot = await AppLogStore.shared.snapshot()
        entries = snapshot.entries
        persistenceError = snapshot.error
    }

    @MainActor
    private func export() {
        let snapshot = filtered
        let scope = "\(level?.title ?? "全部级别")；搜索：\(query.isEmpty ? "无" : query)"
        let info = Bundle.main.infoDictionary ?? [:]
        let metadata = "SignOs \(info["CFBundleShortVersionString"] as? String ?? "?")（\(info["CFBundleVersion"] as? String ?? "?")）\n系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        isWorking = true
        exportTask = Task {
            defer { isWorking = false; exportTask = nil }
            do {
                let url = try await LogExportFile.write(entries: snapshot, metadata: metadata, scope: scope)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                exportDirectory = url.deletingLastPathComponent()
                shareFile = LogShareFile(url: url)
            } catch {
                if !Task.isCancelled { actionError = "导出失败：\(error.localizedDescription)" }
            }
        }
    }

    private func removeExport() {
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }
}

private struct LogRowView: View {
    let entry: AppLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entry.level.title) · \(entry.category)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.level == .error ? Color.red : entry.level == .warning ? Color.orange : Color.primary)
            Text(entry.message)
                .font(.subheadline)
                .lineLimit(3)
            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LogDetailView: View {
    let entry: AppLogEntry

    var body: some View {
        List {
            Section("记录信息") {
                LabeledContent("时间", value: entry.date.formatted(date: .complete, time: .standard))
                LabeledContent("级别", value: entry.level.title)
                LabeledContent("分类", value: entry.category)
            }
            Section("完整内容") {
                Text(entry.message)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("日志详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.message }
                .accessibilityIdentifier("logs-copy")
        }
    }
}

private struct LogShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LogShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
