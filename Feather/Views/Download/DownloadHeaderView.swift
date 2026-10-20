//
//  DownloadHeaderView.swift
//  Feather
//
//  Created by samara on 16.05.2025.
//

import SwiftUI
import Combine
import NimbleExtensions

struct DownloadHeaderView: View {
	@ObservedObject var downloadManager: DownloadManager

	var body: some View {
		ZStack {
			if !downloadManager.manualDownloads.isEmpty {
				VStack {
					VStack(spacing: 12) {
						if let firstDownload = downloadManager.manualDownloads.first {
							DownloadItemView(download: firstDownload)

							if downloadManager.manualDownloads.count > 1 {
								HStack {
									Spacer()
									Text(verbatim: "+\(downloadManager.manualDownloads.count - 1)")
										.font(.caption.weight(.semibold))
										.foregroundStyle(.secondary)
								}
							}
						}
					}
					.padding(.horizontal, 16)
					.padding(.vertical, 6)
				}
				.background {
					ZStack {
						RoundedRectangle(cornerRadius: 22, style: .continuous)
							.fill(.regularMaterial)
						RoundedRectangle(cornerRadius: 22, style: .continuous)
							.strokeBorder(.quaternary, lineWidth: 0.5)
					}
				}
				.padding(.horizontal, 12)
				.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.animation(.spring(), value: downloadManager.manualDownloads.count)
	}
}

struct DownloadItemView: View {
    @ObservedObject var download: Download
    var body: some View { DownloadProgressContent(download: download, showFileName: true) }
}
