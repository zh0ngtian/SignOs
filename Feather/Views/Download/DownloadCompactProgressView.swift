import SwiftUI

struct DownloadCompactProgressView: View {
    @ObservedObject var download: Download
    @State private var speedometer = WSSpeedometer()
    @State private var speedText = ""

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle().trim(from: 0, to: max(0.02, download.overallProgress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 31, height: 31)
                DownloadTransferControls(download: download, compact: true)
            }
            Text(download.state == .downloading && !speedText.isEmpty ? speedText : download.statusText)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 56, minHeight: 44)
        .contextMenu {
            Button("取消下载", systemImage: "xmark.circle", role: .destructive) { DownloadManager.shared.cancelDownload(download) }
                .disabled(download.state == .importing)
        }
        .accessibilityValue("\(download.statusText)，\(Int(download.progress * 100))%")
        .accessibilityHint("轻点暂停或继续，长按可取消下载")
        .onAppear { speedometer.reset(bytes: download.bytesDownloaded) }
        .onReceive(download.$bytesDownloaded) { bytes in
            speedText = download.state == .downloading ? speedometer.sample(bytes).formattedSpeed : ""
        }
        .onChange(of: download.state) {
            speedometer.reset(bytes: download.bytesDownloaded)
            speedText = ""
        }
    }
}
