import Foundation
import Combine

@MainActor
final class Download: ObservableObject, Identifiable {
    enum State: Equatable {
        case checking, downloading, preparing, importing, pausing, paused, failed, requiresRestart
    }
    @Published var progress: Double = 0
    @Published var bytesDownloaded: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var unpackageProgress: Double = 0
    @Published var state: State = .checking
    @Published var message: String?
    var lastNotificationProgress: Double = 0

    nonisolated let id: String
    nonisolated let url: URL
    nonisolated let fileName: String
    nonisolated let onlyArchiving: Bool
    nonisolated let sourceProvenance: SourceAppProvenance?
    nonisolated let targetAppUUID: String?
    nonisolated let importUUID: String
    nonisolated let checkpointID: UUID?
    nonisolated let transferDirectory: URL?

    var overallProgress: Double { onlyArchiving ? unpackageProgress : 0.7 * progress + 0.3 * unpackageProgress }
    var canPause: Bool { state == .checking || state == .downloading || state == .preparing }
    var canContinue: Bool { state == .paused || state == .failed }
    var isActive: Bool { canPause || state == .importing || state == .pausing }
    var statusText: String {
        switch state {
        case .checking: "正在连接"
        case .downloading: "正在下载"
        case .preparing: "正在准备导入"
        case .importing: "正在导入"
        case .pausing: "正在暂停"
        case .paused: "已暂停"
        case .failed: "下载中断"
        case .requiresRestart: "需要重新下载"
        }
    }

    init(id: String, url: URL, onlyArchiving: Bool = false, sourceProvenance: SourceAppProvenance? = nil,
         targetAppUUID: String? = nil, checkpointID: UUID? = nil, transferDirectory: URL? = nil) {
        self.id = id
        self.url = url
        self.fileName = url.lastPathComponent.isEmpty ? "应用包" : url.lastPathComponent
        self.onlyArchiving = onlyArchiving
        self.sourceProvenance = sourceProvenance
        self.targetAppUUID = targetAppUUID
        self.checkpointID = checkpointID
        self.transferDirectory = transferDirectory
        self.importUUID = checkpointID?.uuidString ?? UUID().uuidString
        if onlyArchiving { state = .importing }
    }
}
