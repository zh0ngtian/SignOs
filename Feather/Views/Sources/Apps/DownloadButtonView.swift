//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	@ObservedObject private var updateManager = UpdateManager.shared
	@ObservedObject private var downloadManager = DownloadManager.shared


	var body: some View {
		ZStack {
			if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) {
                DownloadCompactProgressView(download: currentDownload)

			} else {
				Button {
					if let url = app.currentDownloadUrl {
						_ = downloadManager.startDownload(
							from: url,
							id: app.currentUniqueId,
							sourceProvenance: _sourceProvenance()
						)
					}
				} label: {
					Text(.localized(updateManager.hasUpdate(for: app, sourceURL: sourceURL) ? "Update" : "Get"))
						.lineLimit(0)
						.font(.headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, 24)
						.padding(.vertical, 6)
						.background(Color(uiColor: .quaternarySystemFill))
						.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
				.compatTransition()
			}
		}
		.animation(.easeInOut(duration: 0.3), value: downloadManager.getDownload(by: app.currentUniqueId) != nil)
	}

	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
