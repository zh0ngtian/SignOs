//
//  SourcesView.swift
//  Feather
//
//  Source subscriptions and management in one dedicated tab.
//

import SwiftUI
import CoreData
import AltSourceKit
import NukeUI
import NimbleViews

// MARK: - View
struct SourcesView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _autoSourceOverrides: [String: Bool] = [:]
	@State private var _refreshDates: [String: Date] = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	// MARK: Body
	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: WSSpacing.sectionGap) {
					WSHeroHeader(
						eyebrow: "SignOs",
						title: .localized("Sources")
					)

					_remoteManagementCard()

					_sourcesSection()

					if _sources.isEmpty {
						_emptyCard()
					} else {
						_addCard()
					}
				}
				.padding(.horizontal, WSSpacing.screenPadding)
				.padding(.top, WSSpacing.xs)
				.padding(.bottom, WSSpacing.xxl + 8)
			}
			.background(WSSurface.background)
			.toolbar(.hidden, for: .navigationBar)
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
				_markRefreshed()
			}
			.sheet(isPresented: $_isAddingPresenting) {
				SourcesAddView()
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
			_autoSourceOverrides = UserDefaults.standard.dictionary(forKey: "SignOs.sourceAutoUpdate") as? [String: Bool] ?? [:]
			_markRefreshed()
		}
	}
}

// MARK: - Sections
extension SourcesView {
	@ViewBuilder
	private func _sourcesSection() -> some View {
		VStack(alignment: .leading, spacing: 12) {
			WSSectionTitle(title: "Your Sources")

			if _sources.isEmpty {
				Text("Add a repository to start installing apps.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
			} else {
				VStack(spacing: 10) {
					NavigationLink {
						SourceAppsView(object: Array(_sources), viewModel: viewModel)
					} label: {
						_allAppsCard()
					}
					.buttonStyle(.plain)

					ForEach(_sources) { source in
						HStack(spacing: 0) {
							NavigationLink {
								SourceAppsView(object: [source], viewModel: viewModel)
							} label: {
								_sourceCard(source)
							}
							.buttonStyle(.plain)

							Menu {
								_sourceContextMenu(source)
							} label: {
								Image(systemName: "ellipsis.circle")
									.font(.title3)
									.frame(width: 44, height: 44)
							}
							.accessibilityLabel(Text("Manage Source"))
							.accessibilityValue(source.name ?? .localized("Source"))
							.padding(.trailing, 8)
						}
						.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
					}
				}
			}
		}
	}

	private func _remoteManagementCard() -> some View {
		NavigationLink(destination: CloudSourceManagerView()) {
			HStack(spacing: WSSpacing.md) {
				WSIconTile(systemImage: "cloud.fill", color: .cyan)
				Text("管理远端软件源")
					.font(.body.weight(.semibold))
					.foregroundStyle(.primary)
				Spacer()
				Image(systemName: "chevron.forward")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.secondary)
			}
			.padding(WSSpacing.cardPadding)
			.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
		}
		.buttonStyle(.plain)
	}

	private func _allAppsCard() -> some View {
		HStack(spacing: 14) {
			Image(systemName: "square.grid.2x2.fill")
				.font(.system(size: 22, weight: .medium))
				.foregroundStyle(.white)
				.frame(width: 48, height: 48)
				.background(
					RoundedRectangle(cornerRadius: 11, style: .continuous)
						.fill(Color.accentColor)
				)

			NBTitleWithSubtitleView(
				title: "Browse All Apps",
				subtitle: "Everything from every source"
			)

			Spacer()

			Image(systemName: "chevron.forward")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.tertiary)
		}
		.padding(14)
		.background(
			RoundedRectangle(cornerRadius: 20, style: .continuous)
				.fill(Color(uiColor: .secondarySystemGroupedBackground))
		)
	}

	private func _sourceCard(_ source: AltSource) -> some View {
		HStack(spacing: 14) {
			WSAppIcon(url: source.iconURL, size: 48, cornerRadius: 11)

			VStack(alignment: .leading, spacing: 2) {
				Text(source.name ?? "Source")
					.font(.body.weight(.semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(verbatim: _sourceCaption(source))
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer()

			Image(systemName: "chevron.forward")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.tertiary)
		}
		.padding(14)
	}

	private func _emptyCard() -> some View {
		Button {
			_isAddingPresenting = true
		} label: {
			VStack(spacing: 12) {
				Image(systemName: "plus")
					.font(.system(size: 26, weight: .medium))
					.foregroundStyle(.tint)
				Text("Add Your First Source")
					.font(.headline)
					.foregroundStyle(.primary)
				Text("Repositories are where apps come from.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 40)
			.background(
				RoundedRectangle(cornerRadius: 20, style: .continuous)
					.fill(Color(uiColor: .secondarySystemGroupedBackground))
					.overlay(
						RoundedRectangle(cornerRadius: 20, style: .continuous)
							.strokeBorder(
								Color(uiColor: .separator).opacity(0.5),
								style: StrokeStyle(lineWidth: 1.5, dash: [7])
							)
					)
			)
		}
		.buttonStyle(.plain)
	}

	private func _addCard() -> some View {
		Button {
			_isAddingPresenting = true
		} label: {
			HStack(spacing: 10) {
				Image(systemName: "plus.circle.fill")
					.font(.title3)
					.foregroundStyle(.tint)
				Text("Add Source")
					.font(.body.weight(.semibold))
					.foregroundStyle(.tint)
				Spacer()
			}
			.padding(16)
			.background(
				RoundedRectangle(cornerRadius: 20, style: .continuous)
					.fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.6))
					.overlay(
						RoundedRectangle(cornerRadius: 20, style: .continuous)
							.strokeBorder(
								Color(uiColor: .separator).opacity(0.4),
								style: StrokeStyle(lineWidth: 1.2, dash: [6])
							)
					)
			)
		}
		.buttonStyle(.plain)
	}
}

// MARK: - Source health & rules
extension SourcesView {
	private func _sourceContextMenu(_ source: AltSource) -> some View {
		let autoEnabled = _autoSourceOverrides[source.identifier ?? ""] ?? true
		return Group {
			Button {
				let identifier = source.identifier ?? ""
				let now = !(_autoSourceOverrides[identifier] ?? true)
				_autoSourceOverrides[identifier] = now
				AutoUpdateManager.shared.setSourceAutoUpdate(now, for: source)
			} label: {
				Label(
					autoEnabled ? String.localized("Disable Auto-Updates") : String.localized("Enable Auto-Updates"),
					systemImage: "automatic"
				)
			}

			Divider()

			Button(role: .destructive) {
				Storage.shared.deleteSource(for: source)
			} label: {
				Label("Remove Source", systemImage: "trash")
			}
		}
	}

	private func _markRefreshed() {
		for source in _sources {
			_refreshDates[source.identifier ?? ""] = Date()
		}
		UserDefaults.standard.set(_refreshDates, forKey: "SignOs.sourceRefreshDates")
	}

	private func _sourceCaption(_ source: AltSource) -> String {
		let count = viewModel.sources[source]?.apps.count
		let autoOff = !(_autoSourceOverrides[source.identifier ?? ""] ?? true)

		let base: String
		if let count {
			base = count == 1 ? "1 app" : "\(count) apps"
		} else if !viewModel.isFinished {
			return "Refreshing…"
		} else {
			return "Couldn't refresh"
		}

		let suffix = autoOff ? " • Auto-Updates Off" : ""
		if let last = _refreshDates[source.identifier ?? ""] {
			return "\(base) • \(last.formatted(.relative(presentation: .named)))\(suffix)"
		}
		return base + suffix
	}
}
