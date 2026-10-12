//
//  UpdatesView.swift
//  Feather
//
//  Clean, calm updates surface built with the WSTheme design system.
//

import SwiftUI
import CoreData
import NimbleViews

struct UpdatesView: View {
	@StateObject private var autoUpdateManager = AutoUpdateManager.shared
	@ObservedObject private var updateManager = UpdateManager.shared
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var autoSignManager = AutoSignManager.shared
	@State private var _heldTick = 0

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>

	private var _recentlyUpdated: [Signed] {
		let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
		return _signedApps.filter { ($0.date ?? .distantPast) >= cutoff }.prefix(10).map { $0 }
	}

	private var _sortedUpdates: [AppUpdate] {
		updateManager.updates.values.sorted {
			$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
		}
	}

	private var _isChecking: Bool {
		autoUpdateManager.isAutoChecking || updateManager.isChecking
	}

	// MARK: Body

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: WSSpacing.sectionGap) {
					WSHeroHeader(eyebrow: "SignOs", title: "Updates")
					HStack {
						Spacer()
						Button {
							Task { await autoUpdateManager.checkNow(notifyWhenClean: false, syncManagedSources: true) }
						} label: {
							WSSearchCapsuleLabel(title: "Check", isLoading: _isChecking)
								.frame(minHeight: 44)
						}
						.buttonStyle(.plain)
						.disabled(_isChecking)
						.accessibilityLabel(_isChecking ? String.localized("Checking") : String.localized("Check"))
						.accessibilityIdentifier("updates.check")
					}

					if !_sortedUpdates.isEmpty {
						_availableUpdates()
					}

					if !updateManager.checkIssues.isEmpty {
						VStack(alignment: .leading, spacing: WSSpacing.sm) {
							WSSectionHeader(title: "Update Check Incomplete")
							WSCard {
								VStack(alignment: .leading, spacing: WSSpacing.sm) {
									ForEach(updateManager.checkIssues, id: \.self) { issue in
										Text(verbatim: issue).font(.footnote).foregroundStyle(.secondary)
									}
								}
							}
						}
					}

					_heldSection()

					if _hasActivity {
						_activitySection()
					}

					if !_recentlyUpdated.isEmpty {
						_recentSection()
					}

					if _showEmpty {
						WSEmptyState(
							icon: "checkmark.seal.fill",
							title: "All Apps Up to Date",
							message: "Updates from your repositories will appear here automatically."
						)
					}
				}
				.padding(.horizontal, WSSpacing.screenPadding)
				.padding(.top, WSSpacing.xs)
				.padding(.bottom, WSSpacing.xxl + 8)
			}
			.background(WSSurface.background)
			.toolbar(.hidden, for: .navigationBar)
			.refreshable {
				await autoUpdateManager.checkNow(notifyWhenClean: false, syncManagedSources: true)
			}
		}
	}

	private var _hasActivity: Bool {
		autoSignManager.currentJob != nil || !autoSignManager.queue.isEmpty || !downloadManager.downloads.isEmpty
	}

	private var _showEmpty: Bool {
		updateManager.checkIssues.isEmpty && updateManager.lastCheckedDate != nil && _sortedUpdates.isEmpty && downloadManager.downloads.isEmpty && autoSignManager.currentJob == nil && !_isChecking
	}

	// MARK: Available Updates

	@ViewBuilder
	private func _availableUpdates() -> some View {
		VStack(alignment: .leading, spacing: WSSpacing.md) {
			WSSectionHeader(title: "Available Updates")
			HStack {
				Spacer()
				WSSearchCapsuleButton(title: "Update All") { _downloadAll(_sortedUpdates) }
			}

			VStack(spacing: WSSpacing.sm + 2) {
				ForEach(_sortedUpdates, id: \.id) { update in
					_updateCard(update)
				}
			}
		}
	}

	private func _updateCard(_ update: AppUpdate) -> some View {
		HStack(spacing: WSSpacing.md) {
			FRAppIconView(app: _resolve(update), size: 57)
				.overlay(alignment: .topTrailing) {
					Circle()
						.fill(Color.accentColor)
						.frame(width: 10, height: 10)
						.offset(x: 4, y: -4)
				}

			VStack(alignment: .leading, spacing: 3) {
				Text(update.appName)
					.font(.body.weight(.semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(verbatim: _versionText(update))
					.font(WSType.cardSubtitle)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}

			Spacer()

			WSSearchCapsuleButton(title: "Update") { _download(update) }
		}
		.padding(WSSpacing.cardPadding)
		.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
		.contextMenu {
			Button { _download(update) } label: { Label("Update", systemImage: "arrow.down.circle") }
			Divider()
			Menu {
				Button { autoUpdateManager.setAutoUpdate(true, for: update.bundleIdentifier) }
					label: { Label("Automatic", systemImage: "checkmark.circle.fill") }
				Button { autoUpdateManager.setAutoUpdate(false, for: update.bundleIdentifier) }
					label: { Label("Manual", systemImage: "hand.tap") }
			} label: { Label("Auto-Update", systemImage: "automatic") }
			Divider()
			Button {
				updateManager.skip(version: update.remoteVersion, for: update.bundleIdentifier)
				updateManager.dismissUpdate(withLocalUUID: update.id)
			} label: { Label("Skip This Version", systemImage: "eye.slash") }
			Button {
				updateManager.setHeld(true, for: update.bundleIdentifier)
				updateManager.dismissUpdate(withLocalUUID: update.id)
			} label: { Label("Hold Updates for This App", systemImage: "pause.circle") }
		}
	}

	// MARK: Activity

	@ViewBuilder
	private func _activitySection() -> some View {
		VStack(alignment: .leading, spacing: WSSpacing.md) {
			WSSectionHeader(title: "Activity")

			VStack(spacing: WSSpacing.sm + 2) {
				if let job = autoSignManager.currentJob {
					_queueCard(job, isActive: true)
				}
				ForEach(autoSignManager.queue) { job in
					_queueCard(job, isActive: false)
				}
				ForEach(downloadManager.downloads, id: \.id) { download in
					WSDownloadCard(download: download)
				}
			}
		}
	}

	private func _queueCard(_ job: AutoSignManager.Job, isActive: Bool) -> some View {
		HStack(spacing: WSSpacing.md) {
			Image(systemName: isActive ? "square.and.arrow.down.fill" : "hourglass")
				.font(.title3)
				.foregroundStyle(isActive ? Color.accentColor : Color.secondary)
				.frame(width: 30)

			VStack(alignment: .leading, spacing: 2) {
				Text(job.appName ?? .localized("Unknown"))
					.font(.body.weight(.semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(_reasonLabel(job.reason))
					.font(WSType.micro)
					.foregroundStyle(.secondary)
			}

			Spacer()

			if isActive { ProgressView() }
		}
		.padding(WSSpacing.cardPadding)
		.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
	}

	// MARK: Recently Updated

	@ViewBuilder
	private func _recentSection() -> some View {
		VStack(alignment: .leading, spacing: WSSpacing.md) {
			WSSectionHeader(title: "Recently Updated")

			VStack(spacing: WSSpacing.sm + 2) {
				ForEach(_recentlyUpdated, id: \.uuid) { app in
					HStack(spacing: WSSpacing.md) {
						FRAppIconView(app: app, size: 57)

						VStack(alignment: .leading, spacing: 3) {
							Text(app.name ?? .localized("Unknown"))
								.font(.body.weight(.semibold))
								.foregroundStyle(.primary)
								.lineLimit(1)
							Text(verbatim: [
								app.version,
								(app.date ?? .distantPast).formatted(.relative(presentation: .named))
							].compactMap { $0 }.joined(separator: " • "))
								.font(WSType.micro)
								.foregroundStyle(.secondary)
								.lineLimit(2)
						}

						Spacer()

						WSSearchCapsuleButton(title: "Open") {
							UIApplication.openApp(with: app.identifier ?? "")
						}
					}
					.padding(WSSpacing.cardPadding)
					.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
				}
			}
		}
	}

	// MARK: Held & Skipped

	@ViewBuilder
	private func _heldSection() -> some View {
		let rows = _heldApps()
		if !rows.isEmpty {
			VStack(alignment: .leading, spacing: WSSpacing.md) {
				WSSectionHeader(title: "Held & Skipped")

				VStack(spacing: WSSpacing.sm + 2) {
					ForEach(rows, id: \.identifier) { row in
						HStack(spacing: WSSpacing.md) {
							Image(systemName: row.held ? "pause.circle.fill" : "eye.slash.fill")
								.font(.title3)
								.foregroundStyle(.secondary)
								.frame(width: 30)

							VStack(alignment: .leading, spacing: 2) {
								Text(row.name)
									.font(.body.weight(.semibold))
									.foregroundStyle(.primary)
									.lineLimit(1)
								Text(verbatim: row.held ? .localized("Updates held") : .localized("Skipped %@", arguments: row.skipped ?? ""))
									.font(WSType.micro)
									.foregroundStyle(.secondary)
							}

							Spacer()

							WSSearchCapsuleButton(title: row.held ? "Resume" : "Unskip") {
								if row.held {
									updateManager.setHeld(false, for: row.identifier)
								} else {
									updateManager.clearSkip(for: row.identifier)
								}
								_heldTick += 1
							}
						}
						.padding(WSSpacing.cardPadding)
						.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
					}
				}
			}
		}
	}

	// MARK: Helpers

	private func _reasonLabel(_ reason: AutoSignManager.Reason) -> String {
		switch reason {
		case .autoSign: return .localized("Installing")
		case .autoUpdate: return .localized("Installing Update")
		case .renewal: return .localized("Refreshing")
		}
	}

	private func _versionText(_ update: AppUpdate) -> String {
		if let local = update.localVersion, !local.isEmpty {
			return "\(local) → \(update.remoteVersion)"
		}
		return update.remoteVersion
	}

	private func _resolve(_ update: AppUpdate) -> (any AppInfoPresentable)? {
		_signedApps.first { $0.uuid == update.localUUID }
	}

	private func _heldApps() -> [(identifier: String, name: String, held: Bool, skipped: String?)] {
		var seen = Set<String>()
		var rows: [(identifier: String, name: String, held: Bool, skipped: String?)] = []
		for app in _signedApps.map({ $0 as (any AppInfoPresentable) }) + _importedApps.map({ $0 as (any AppInfoPresentable) }) {
			guard let identifier = app.identifier, !seen.contains(identifier) else { continue }
			let held = updateManager.isHeld(for: identifier)
			let skipped = updateManager.skippedVersion(for: identifier)
			if held || skipped != nil {
				seen.insert(identifier)
				rows.append((identifier, app.name ?? identifier, held, skipped))
			}
		}
		return rows
	}

	private func _download(_ update: AppUpdate) {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		_performUpdate(update)
	}

	private func _performUpdate(_ update: AppUpdate) {
		let apps: [any AppInfoPresentable] = _signedApps.map { $0 } + _importedApps.map { $0 }
		if let cached = updateManager.downloadedApp(for: update, among: apps, isPackageAvailable: {
			guard let directory = Storage.shared.getAppDirectory(for: $0) else { return false }
			return FileManager.default.fileExists(atPath: directory.appendingPathComponent("Info.plist").path)
		}) {
			if let signed = cached as? Signed {
				autoSignManager.enqueueInstall(app: signed)
			} else {
				autoSignManager.enqueue(app: cached, reason: .autoUpdate, force: true)
			}
			return
		}
		_ = DownloadManager.shared.startDownload(
			from: update.downloadURL,
			id: "SignOsManualUpdate_\(update.localUUID)",
			sourceProvenance: update.sourceProvenance
		)
	}

	private func _downloadAll(_ updates: [AppUpdate]) {
		UIImpactFeedbackGenerator(style: .medium).impactOccurred()
		for update in updates {
			_performUpdate(update)
		}
	}
}

// MARK: - Download Card

struct WSDownloadCard: View {
	let download: Download

	@State private var _speedometer = WSSpeedometer()
	@State private var _speedText = ""
	@State private var _etaText = ""

	var body: some View {
		VStack(alignment: .leading, spacing: WSSpacing.sm) {
			HStack(spacing: WSSpacing.sm + 2) {
				Image(systemName: "arrow.down.circle.fill")
					.font(.title3)
					.foregroundStyle(.tint)
					.symbolRenderingMode(.hierarchical)

				Text(download.fileName)
					.font(.footnote.weight(.semibold))
					.lineLimit(1)

				Spacer()

				Text(verbatim: "\(Int(download.overallProgress * 100))%")
					.font(.caption.weight(.semibold).monospacedDigit())
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())

				Button {
					if let dl = DownloadManager.shared.getDownload(by: download.id) {
						DownloadManager.shared.cancelDownload(dl)
					}
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.tertiary)
				}
				.buttonStyle(.plain)
			}

			ProgressView(value: download.overallProgress)
				.progressViewStyle(.linear)

			HStack(spacing: WSSpacing.xs) {
				if download.totalBytes > 0 {
					Text(verbatim: download.totalBytes.formattedByteCount)
				}
				if !_speedText.isEmpty {
					Text(verbatim: "• \(_speedText)")
				}
				if !_etaText.isEmpty {
					Text(verbatim: "• \(_etaText)")
				}
			}
			.font(WSType.micro)
			.foregroundStyle(.tertiary)
		}
		.padding(WSSpacing.cardPadding)
		.background(WSRadius.continuous(WSRadius.lg).fill(WSSurface.card))
		.onReceive(download.$bytesDownloaded) { bytes in
			let speed = _speedometer.sample(bytes)
			_speedText = speed.formattedSpeed
			if speed > 0, download.totalBytes > bytes {
				_etaText = (Double(download.totalBytes - bytes) / speed).formattedEta
			} else {
				_etaText = ""
			}
		}
	}
}
