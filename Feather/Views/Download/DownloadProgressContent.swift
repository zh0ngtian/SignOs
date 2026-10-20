import SwiftUI
import NimbleExtensions

struct DownloadProgressContent: View {
    @ObservedObject var download: Download
    var showFileName = false
    @State private var speedometer = WSSpeedometer()
    @State private var speedText = ""
    @State private var etaText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(showFileName ? download.fileName : download.statusText)
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                    if showFileName { Text(download.statusText).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(Int(download.overallProgress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                DownloadTransferControls(download: download)
            }
            ProgressView(value: download.overallProgress).progressViewStyle(.linear)
            HStack(spacing: 6) {
                if download.totalBytes > 0 {
                    Text(verbatim: "\(download.bytesDownloaded.formattedByteCount) / \(download.totalBytes.formattedByteCount)")
                } else if download.bytesDownloaded > 0 {
                    Text(verbatim: download.bytesDownloaded.formattedByteCount)
                }
                if !speedText.isEmpty { Text(verbatim: speedText) }
                if !etaText.isEmpty { Text(verbatim: etaText) }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if let message = download.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { speedometer.reset(bytes: download.bytesDownloaded) }
        .onReceive(download.$bytesDownloaded) { bytes in
            let speed = speedometer.sample(bytes)
            speedText = download.state == .downloading ? speed.formattedSpeed : ""
            etaText = speed > 0 && download.totalBytes > bytes && download.state == .downloading
                ? (Double(download.totalBytes - bytes) / speed).formattedEta : ""
        }
        .onChange(of: download.state) {
            speedometer.reset(bytes: download.bytesDownloaded)
            speedText = ""
            etaText = ""
        }
    }
}
