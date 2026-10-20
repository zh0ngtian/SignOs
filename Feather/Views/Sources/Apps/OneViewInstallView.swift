//
//  OneViewInstallView.swift
//  Feather
//
//  One-view install: GET → downloading → installing → open,
//  the entire journey on a single screen.
//

import SwiftUI
import Combine
import CoreData
import AltSourceKit
import NimbleViews

// MARK: - Phase
extension OneViewPhase {
	var buttonTitle: String {
		switch self {
		case .idle: return "Get"
		case .downloading: return ""
		case .preparing: return "Installing"
		case .needsSign: return "Sign & Install"
		case .ready: return "Install"
		case .installed: return "Open"
		}
	}
}

// MARK: - Phase resolver
struct OneViewTracker {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	var startedAt: Date

	@MainActor
	func phase(downloadManager: DownloadManager, autoSignManager: AutoSignManager, signed: [Signed], imported: [Imported]) -> OneViewPhase {
		let queueJobs = (autoSignManager.currentJob.map { [$0] } ?? []) + autoSignManager.queue

		let identifier = app.id
		let provenance = source.flatMap { SourceAppProvenance(sourceURL: sourceURL, repository: $0, app: app) }
        let newestSigned = signed
			.filter { $0.identifier == identifier && AppOperations.matchesSourcePackage($0, provenance: provenance) && (provenance != nil || ($0.date ?? .distantPast) >= startedAt || $0.version == app.currentVersion) }
			.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
		let newestImported = imported
			.filter { $0.identifier == identifier && AppOperations.matchesSourcePackage($0, provenance: provenance) && (provenance != nil || ($0.date ?? .distantPast) >= startedAt || $0.version == app.currentVersion) }
			.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
		return .resolve(
			downloading: downloadManager.getDownload(by: app.currentUniqueId) != nil,
			queued: queueJobs.contains { $0.appIdentifier == app.id } || SourceAccessManager.shared.hasActiveApplication(identifier ?? ""),
			signed: newestSigned != nil,
			installed: newestSigned?.uuid.map { autoSignManager.confirmedInstallUUIDs.contains($0) } ?? false,
			imported: newestImported != nil
		)
	}
}

// MARK: - Inline Get button (lists & carousels)
struct WSOneViewGetButton: View {
	let idleTitle: String
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App

	init(sourceURL: URL?, source: ASRepository?, app: ASRepository.App, idleTitle: String = "Get") {
		self.idleTitle = idleTitle
		self.sourceURL = sourceURL
		self.source = source
		self.app = app
	}

	@ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var sourceAccess = SourceAccessManager.shared
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var autoSignManager = AutoSignManager.shared
	@State private var _tappedGet = false
	@State private var _installError: String?
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

	@State private var _startedAt = Date()
	@State private var _presentingInstall = false
	@State private var _presentingSign = false

	var body: some View {
		let tracker = OneViewTracker(sourceURL: sourceURL, source: source, app: app, startedAt: _startedAt)
		let phase = tracker.phase(
			downloadManager: downloadManager,
			autoSignManager: autoSignManager,
			signed: Array(_signedApps),
			imported: Array(_importedApps)
		)

		Group {
			let phase: OneViewPhase = (phase == .idle && _tappedGet) ? .preparing : phase
			switch phase {
			case .idle:
				Button {
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
					_tappedGet = true
					if let url = app.currentDownloadUrl {
						_startedAt = Date()
						AppOperations.obtain(
							url: url,
							id: app.currentUniqueId,
							provenance: _provenance()
						)
					}
				} label: {
					WSSearchCapsuleLabel(title: updateManager.hasUpdate(for: app, sourceURL: sourceURL) ? "Update" : idleTitle)
						.frame(minHeight: 44)
				}
				.buttonStyle(.borderless)
            case .downloading:
                if let download = downloadManager.getDownload(by: app.currentUniqueId) {
                    DownloadCompactProgressView(download: download)
                }
			case .preparing:
				VStack(spacing: 3) {
					ProgressView()
						.frame(width: 31, height: 31)
					Text(.localized("Installing"))
						.font(.system(size: 8, weight: .semibold))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				.frame(width: 56)
			case .needsSign:
				Button {
					_presentingSign = true
				} label: {
					Text(.localized("Sign"))
						.lineLimit(0)
						.font(.headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, 20)
						.padding(.vertical, 6)
						.background(Color(uiColor: .quaternarySystemFill))
						.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
			case .ready:
				Button {
                    if let signed = _newestSigned() { autoSignManager.enqueueInstall(app: signed) }
				} label: {
					WSSearchCapsuleLabel(title: "Install")
						.frame(minHeight: 44)
				}
				.buttonStyle(.borderless)
			case .installed:
				Button {
					UIApplication.openApp(with: app.id ?? "")
				} label: {
					Text(.localized("Open"))
						.lineLimit(0)
						.font(.headline.bold())
						.foregroundStyle(Color.white)
						.padding(.horizontal, 20)
						.padding(.vertical, 6)
						.background(Color.green)
						.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
			}
		}
		.animation(.easeInOut(duration: 0.3), value: phase)
		.onChange(of: autoSignManager.installErrors[app.id ?? ""]) { message in
			_installError = message
		}
		.alert(.localized("Install"), isPresented: Binding(
			get: { _installError != nil },
			set: { if !$0 { _installError = nil } }
		)) {
			Button(.localized("OK"), role: .cancel) { _installError = nil }
		} message: {
			Text(_installError ?? "")
		}
        .disabled(phase != .installed && !SourcePolicy.isEnabled(url: sourceURL, identifier: source?.id))
		.sheet(isPresented: $_presentingInstall) {
			if let installed = _newestSigned() {
				InstallPreviewView(app: installed)
			}
		}
		.fullScreenCover(isPresented: $_presentingSign) {
			if let imported = _newestImported() {
				SigningView(app: imported)
			}
		}
		.onAppear {
			_startedAt = Date()
		}
		.onChange(of: phase) { newPhase in
			if newPhase == .installed || newPhase == .ready || newPhase == .needsSign { _tappedGet = false }
		}
        .onChange(of: downloadManager.downloads.map(\.id)) {
            if tracker.phase(downloadManager: downloadManager, autoSignManager: autoSignManager,
                             signed: Array(_signedApps), imported: Array(_importedApps)) == .idle {
                _tappedGet = false
            }
        }
	}

	private func _provenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}

	private func _newestSigned() -> Signed? {
		_signedApps
			.filter { $0.identifier == app.id && AppOperations.matchesSourcePackage($0, provenance: _provenance()) && (_provenance() != nil || ($0.date ?? .distantPast) >= _startedAt || $0.version == app.currentVersion) }
			.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
	}

	private func _newestImported() -> Imported? {
		_importedApps
			.filter { $0.identifier == app.id && AppOperations.matchesSourcePackage($0, provenance: _provenance()) && (_provenance() != nil || ($0.date ?? .distantPast) >= _startedAt || $0.version == app.currentVersion) }
			.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
	}
}

// MARK: - The one-view sheet
struct OneViewInstallView: View {
	@Environment(\.dismiss) var dismiss

	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App

	@ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var sourceAccess = SourceAccessManager.shared
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var autoSignManager = AutoSignManager.shared
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

	@State private var _startedAt = Date()
	@State private var _presentingInstall = false
	@State private var _signingApp: Imported?
	@State private var _tappedGet = false
	@State private var _installError: String?

	private var tracker: OneViewTracker {
		OneViewTracker(sourceURL: sourceURL, source: source, app: app, startedAt: _startedAt)
	}

	private var _download: Download? {
		downloadManager.getDownload(by: app.currentUniqueId)
	}

	private var _newestInstalled: Signed? {
		_signedApps
			.filter { $0.identifier == app.id && AppOperations.matchesSourcePackage($0, provenance: _provenance()) && (_provenance() != nil || ($0.date ?? .distantPast) >= _startedAt || $0.version == app.currentVersion) }
			.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
	}

	private var _newestImported: Imported? {
		_importedApps
			.filter { $0.identifier == app.id && AppOperations.matchesSourcePackage($0, provenance: _provenance()) && (_provenance() != nil || ($0.date ?? .distantPast) >= _startedAt || $0.version == app.currentVersion) }
			.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
	}

	private var _phase: OneViewPhase {
		let resolved = tracker.phase(
			downloadManager: downloadManager,
			autoSignManager: autoSignManager,
			signed: Array(_signedApps),
			imported: Array(_importedApps)
		)
		return (resolved == .idle && _tappedGet) ? .preparing : resolved
	}

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(spacing: 22) {
					VStack(spacing: 12) {
						WSAppIcon(url: app.iconURL, size: 100)
						Text(app.currentName)
							.font(.title2.weight(.bold))
							.multilineTextAlignment(.center)
						Text(verbatim: [
							app.currentVersion,
							source?.name
						].compactMap { $0 }.joined(separator: " • "))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity)

					_statusCard()

					if let whatsNew = app.currentAppVersion?.localizedDescription,
					   !whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
						VStack(alignment: .leading, spacing: 8) {
							Text("What's New")
								.font(.headline)
							Text(whatsNew)
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(16)
						.background(
							RoundedRectangle(cornerRadius: 20, style: .continuous)
								.fill(Color(uiColor: .secondarySystemGroupedBackground))
						)
					}

					if let description = app.localizedDescription {
						VStack(alignment: .leading, spacing: 8) {
							Text("Description")
								.font(.headline)
							Text(description)
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(16)
						.background(
							RoundedRectangle(cornerRadius: 20, style: .continuous)
								.fill(Color(uiColor: .secondarySystemGroupedBackground))
						)
					}
				}
				.padding(16)
				.padding(.bottom, 24)
			}
			.background(Color(uiColor: .systemGroupedBackground))
			.navigationTitle("Install")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				NBToolbarButton(role: .dismiss)
			}
			.onChange(of: autoSignManager.installErrors[app.id ?? ""]) { message in
				_installError = message
			}
			.alert(.localized("Install"), isPresented: Binding(
				get: { _installError != nil },
				set: { if !$0 { _installError = nil } }
			)) {
				Button(.localized("OK"), role: .cancel) { _installError = nil }
			} message: {
				Text(_installError ?? "")
			}
			.sheet(isPresented: $_presentingInstall) {
				if let installed = _newestInstalled {
					InstallPreviewView(app: installed)
				}
			}
			.fullScreenCover(item: $_signingApp) { imported in
				SigningView(app: imported)
			}
			.onAppear { _startedAt = Date() }
            .onChange(of: downloadManager.downloads.map(\.id)) {
                if tracker.phase(downloadManager: downloadManager, autoSignManager: autoSignManager,
                                 signed: Array(_signedApps), imported: Array(_importedApps)) == .idle {
                    _tappedGet = false
                }
            }
			.onChange(of: _phase) { newPhase in
				if newPhase == .installed || newPhase == .ready || newPhase == .needsSign { _tappedGet = false }
			}
		}
	}
}

// MARK: - Status card
extension OneViewInstallView {
	@ViewBuilder
	private func _statusCard() -> some View {
		let phase = _phase

		VStack(spacing: 14) {
			switch phase {
			case .idle, .needsSign:
				Button {
					if phase == .needsSign, let imported = _newestImported {
						// signing automation is off — hand it to the sign flow
						_dismissAndPresentSign(imported)
						return
					}
					_tappedGet = true
					if let url = app.currentDownloadUrl {
						AppOperations.obtain(
							url: url,
							id: app.currentUniqueId,
							provenance: _provenance()
						)
					}
				} label: {
					_prominentButton(
						title: phase == .needsSign ? "Sign & Install" :
							(updateManager.hasUpdate(for: app, sourceURL: sourceURL) ? "Update" : "Get"),
						systemImage: "arrow.down.circle.fill",
						color: .accentColor
					)
				}
				.buttonStyle(.plain)

				Text(phase == .needsSign
					? .localized("Downloaded. Turn on Auto-Sign in Settings for one-tap installs.")
					: .localized("Downloads, signs and installs automatically."))
					.font(.caption)
					.foregroundStyle(.secondary)

            case .downloading:
                if let download = _download {
                    DownloadProgressContent(download: download)
                    Text("After the download it signs and installs automatically.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

			case .preparing:
				HStack(spacing: 12) {
					ProgressView()
					VStack(alignment: .leading, spacing: 3) {
						Text("Installing…")
							.font(.subheadline.weight(.semibold))
						Text("Signing and preparing. You'll be notified when it's ready.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
				}

			case .ready:
				Button {
                    if let signed = _newestInstalled { autoSignManager.enqueueInstall(app: signed) }
				} label: {
					_prominentButton(title: "Install Now", systemImage: "square.and.arrow.down.fill", color: .accentColor)
				}
				.buttonStyle(.plain)
				Text("Signed and ready. One tap to install.")
					.font(.caption)
					.foregroundStyle(.secondary)

			case .installed:
				Button {
					UIApplication.openApp(with: app.id ?? "")
				} label: {
					_prominentButton(title: "Open", systemImage: "app.badge.fill", color: .green)
				}
				.buttonStyle(.plain)
				Text("Installed on this device.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity)
		.background(
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.fill(Color(uiColor: .secondarySystemGroupedBackground))
		)
		.animation(.smooth, value: phase)
	}

	private func _prominentButton(title: String, systemImage: String, color: Color) -> some View {
		HStack(spacing: 8) {
			Image(systemName: systemImage)
			Text(.localized(title))
				.font(.headline)
		}
		.foregroundStyle(.white)
		.frame(maxWidth: .infinity)
		.frame(minHeight: 48)
		.background(
			RoundedRectangle(cornerRadius: 15, style: .continuous)
				.fill(color)
		)
	}

	private func _provenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}

	private func _dismissAndPresentSign(_ imported: Imported) {
		_signingApp = imported
	}
}
