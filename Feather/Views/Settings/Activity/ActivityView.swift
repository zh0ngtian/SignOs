//
//  ActivityView.swift
//  Feather
//
//  Timeline of automatic background activity.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ActivityView: View {
	@StateObject private var log = ActivityLog.shared

	var body: some View {
		NBNavigationView(.localized("Activity")) {
			Group {
				if log.entries.isEmpty {
					ContentUnavailableCompatView(
						title: "No Activity Yet",
						message: "Automatic downloads, installs and renewals will appear here."
					)
				} else {
					List {
						ForEach(log.entries) { entry in
							HStack(spacing: 14) {
								Image(systemName: entry.kind.symbol)
									.font(.body)
									.foregroundStyle(_color(for: entry.kind))
									.frame(width: 30)

								VStack(alignment: .leading, spacing: 3) {
									Text(verbatim: "\(entry.kind.title) \(entry.app)")
										.font(.subheadline.weight(.semibold))
										.lineLimit(2)
									HStack(spacing: 4) {
										Text(entry.date.formatted(.relative(presentation: .named)))
										if let detail = entry.detail {
											Text(verbatim: "• \(detail)")
												.lineLimit(1)
										}
									}
									.font(.caption)
									.foregroundStyle(.secondary)
								}
							}
							.padding(.vertical, 2)
						}
					}
				}
			}
		}
		.navigationTitle(.localized("Activity"))
	}

	private func _color(for kind: ActivityEntry.Kind) -> Color {
		switch kind {
		case .checked: return .secondary
		case .downloaded: return .blue
		case .installed: return .green
		case .updated: return .mint
		case .renewed: return .teal
		case .failed: return .red
		}
	}
}

// MARK: - Shared empty state
struct ContentUnavailableCompatView: View {
	let title: String
	let message: String

	var body: some View {
		ContentUnavailableView(title, systemImage: "clock.arrow.circlepath", description: Text(message))
	}
}
