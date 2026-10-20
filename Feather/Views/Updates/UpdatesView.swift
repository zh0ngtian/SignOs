//
//  UpdatesView.swift
//  Feather
//
//  Clean, calm updates surface built with the WSTheme design system.
//

import SwiftUI
import CoreData
import NimbleViews

// Compatibility entry point for older navigation links.
struct UpdatesView: View {
    var body: some View { LibraryView() }
}

// MARK: - Available Update Card

struct WSAvailableUpdateCard<Icon: View>: View {
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize

	let appName: String
	let versionText: String
	let whatsNew: String?
	let onUpdate: () -> Void
	@ViewBuilder let icon: () -> Icon

	private var releaseNotes: String? {
		guard let notes = whatsNew?.trimmingCharacters(in: .whitespacesAndNewlines),
			!notes.isEmpty else { return nil }
		return notes
	}

	var body: some View {
		VStack(alignment: .leading, spacing: WSSpacing.lg) {
			if dynamicTypeSize.isAccessibilitySize {
				VStack(alignment: .leading, spacing: WSSpacing.sm) {
					appInfo
					HStack {
						Spacer()
						updateButton
					}
				}
			} else {
				HStack(spacing: WSSpacing.md) {
					appInfo
					Spacer(minLength: WSSpacing.sm)
					updateButton
				}
			}

			if let releaseNotes {
				Text(verbatim: releaseNotes)
					.font(.body)
					.foregroundStyle(.primary)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				Text("No release notes available")
					.font(.body)
					.foregroundStyle(.secondary)
			}

			Text(verbatim: versionText)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(WSSpacing.cardPadding)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
	}

	private var appInfo: some View {
		HStack(spacing: WSSpacing.md) {
			icon()
				.accessibilityHidden(true)
			Text(verbatim: appName)
				.font(.body.weight(.semibold))
				.foregroundStyle(.primary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var updateButton: some View {
		WSSearchCapsuleButton(title: "Update", action: onUpdate)
			.fixedSize()
			.accessibilityLabel(String.localized("Update") + " " + appName)
	}
}

// MARK: - Download Card

struct WSDownloadCard: View {
    @ObservedObject var download: Download
    var body: some View {
        DownloadProgressContent(download: download, showFileName: true)
            .padding(WSSpacing.cardPadding)
            .background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
    }
}
