import SwiftUI

struct DownloadTransferControls: View {
    @ObservedObject var download: Download
    var compact = false
    @State private var confirmsRestart = false

    private var title: String {
        if download.state == .requiresRestart { return "重新下载" }
        if download.canContinue { return "继续下载" }
        return "暂停下载"
    }
    private var symbol: String {
        if download.state == .requiresRestart { return "arrow.clockwise" }
        if download.canContinue { return "play.fill" }
        if download.state == .pausing { return "hourglass" }
        if download.state == .importing { return "archivebox" }
        return "pause.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(title, systemImage: symbol) {
                if download.state == .requiresRestart { confirmsRestart = true }
                else if download.canContinue { DownloadManager.shared.resumeDownload(download) }
                else { DownloadManager.shared.pauseDownload(download) }
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(download.state == .pausing || download.state == .importing)
            .accessibilityIdentifier("download-primary-\(download.id)")

            if !compact {
                Button("取消下载", systemImage: "xmark.circle.fill", role: .destructive) { DownloadManager.shared.cancelDownload(download) }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    .disabled(download.state == .importing)
            }
        }
        .buttonStyle(.plain)
        .alert("需要重新下载", isPresented: $confirmsRestart) {
            Button("从头重新下载", role: .destructive) { DownloadManager.shared.restartDownload(download) }
            Button("保留当前进度", role: .cancel) { }
        } message: {
            Text(download.message ?? "无法确认服务器文件与已下载部分一致。重新下载将清除本任务的旧进度。")
        }
    }
}
