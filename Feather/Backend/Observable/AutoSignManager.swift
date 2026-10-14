//
//  AutoSignManager.swift
//  Feather
//
//  Serial background signing queue. Imported/updated/renewal apps are
//  signed with the correct certificate without any user interaction,
//  installation is attempted immediately when the active method supports it,
//  and old packages are cleaned up only after the installation-end signal.
//

import Foundation
import Combine
import CoreData
import UIKit
import IDeviceSwift
import SafariServices
import NimbleExtensions

@MainActor
final class AutoSignManager: ObservableObject {
	static let shared = AutoSignManager()

	enum Reason: String {
		case autoSign
		case autoUpdate
		case renewal
	}

	struct Job: Identifiable {
		let id = UUID().uuidString
		let appUUID: String
		let reason: Reason
		let appIdentifier: String?
		let appName: String?
		var certificate: CertificatePair? = nil
		var options: Options? = nil
		var retryCount: Int = 0
		var installOnly = false
	}

	@Published private(set) var queue: [Job] = []
	@Published private(set) var currentJob: Job?
	@Published private(set) var currentPhase = ""
	private var suppressedJobs = Set<String>()
	@Published private(set) var completedCount = 0
	@Published private(set) var lastErrorMessage: String?
	@Published private(set) var confirmedInstallUUIDs: Set<String> = []
	@Published private(set) var installErrors: [String: String] = [:]

	private var _isRunning = false

	/// Keeps local install servers alive until the system fetches the payload.
	private static var _liveInstallers: [ServerInstaller] = []
    private static var installLeases: [String: String] = [:]
    private static var installObservers: [String: AnyCancellable] = [:]
    private static var installBrowsers: [UUID: InstallationBrowserPresentation] = [:]

	private init() {
		UIDevice.current.isBatteryMonitoringEnabled = true
		NotificationCenter.default.addObserver(
			forName: Notification.Name("SignOs.autoInstallRequested"),
			object: nil,
			queue: .main
		) { [weak self] note in
			guard let uuid = note.userInfo?["uuid"] as? String else { return }
			Task { @MainActor in
				await self?._handleInstallRequest(uuid: uuid)
			}
		}
	}

	// MARK: - Settings

	var isAutoSignEnabled: Bool {
		get { UserDefaults.standard.object(forKey: "SignOs.autoSignEnabled") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "SignOs.autoSignEnabled") }
	}

	// MARK: - Per-app certificate pins

	static func pinnedCertificateUUID(for identifier: String) -> String? {
		let pins = UserDefaults.standard.dictionary(forKey: "SignOs.appCertificatePins") as? [String: String] ?? [:]
		return pins[identifier]
	}

	static func setPinnedCertificate(_ uuid: String?, for identifier: String) {
		var pins = UserDefaults.standard.dictionary(forKey: "SignOs.appCertificatePins") as? [String: String] ?? [:]
		if let uuid {
			pins[identifier] = uuid
		} else {
			pins.removeValue(forKey: identifier)
		}
		UserDefaults.standard.set(pins, forKey: "SignOs.appCertificatePins")
	}

	// MARK: - Enqueueing

	/// Reuse an already signed update without creating another signed copy.
	func enqueueInstall(app: Signed) {
		guard let uuid = app.uuid, AppOperations.isAllowed(app), !SourceAccessManager.shared.hasActiveApplication(app.identifier ?? "") else { return }
		if let versionID = Storage.shared.sourceMetadata(for: app)?.sourceVersionID {
			let jobs = queue + (currentJob.map { [$0] } ?? [])
			guard !jobs.contains(where: { job in
				Storage.shared.sourceMetadata(for: job.appUUID)?.sourceVersionID == versionID
			}) else { return }
		}
		enqueue(job: Job(
			appUUID: uuid, reason: .autoUpdate,
			appIdentifier: app.identifier, appName: app.name, installOnly: true
		))
	}

	/// Queues an app for background signing.
	func enqueue(
		app: AppInfoPresentable,
		reason: Reason = .autoSign,
		certificate: CertificatePair? = nil,
		options: Options? = nil,
		force: Bool = false
	) {
		guard force || isAutoSignEnabled else { return }
		guard let uuid = app.uuid, AppOperations.isAllowed(app) else { return }

		let job = Job(
			appUUID: uuid,
			reason: reason,
			appIdentifier: options?.appIdentifier ?? app.identifier,
			appName: options?.appName ?? app.name,
			certificate: certificate,
			options: options
		)
		enqueue(job: job)
	}

	/// Clones an app: same app, new identity, parallel install.
	func cloneApp(app: AppInfoPresentable) {
		var options = OptionsManager.shared.options
		let base = app.identifier ?? UUID().uuidString
		options.appIdentifier = "\(base).clone\(Int.random(in: 100...999))"
		options.appName = "\(app.name ?? .localized("App")) \(Int.random(in: 2...9))"
		options.signingOption = .default

		let certificate = Storage.shared.getCertificate(from: app)
			?? _certificate(for: app, options: options)

		enqueue(app: app, reason: .autoSign, certificate: certificate, options: options, force: true)
	}

	/// Resolves an imported app by uuid and queues it. Safe to call for
	/// every import: duplicates and already signed apps are filtered.
	func enqueueImported(uuid: String, targetAppUUID: String? = nil, force: Bool = false) {
		guard force || isAutoSignEnabled else { return }

		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		guard let app = (try? Storage.shared.context.fetch(request))?.first else { return }

		var options = OptionsManager.shared.options
        var cert: CertificatePair?
        if let targetAppUUID, let baseline = _resolveApp(uuid: targetAppUUID) {
            options.appIdentifier = baseline.identifier
            if baseline.identifier != app.identifier { options.appName = baseline.name }
            cert = AppOperations.certificate(for: baseline)
        }
        enqueue(app: app, reason: targetAppUUID == nil ? .autoSign : .autoUpdate, certificate: cert, options: options, force: force)
	}

    func cancelPending(where matches: (any AppInfoPresentable) -> Bool) {
        queue.removeAll { job in _resolveApp(uuid: job.appUUID).map(matches) ?? true }
        if let job = currentJob, let app = _resolveApp(uuid: job.appUUID), matches(app) { suppressedJobs.insert(job.id) }
    }

    private func enqueue(job: Job) {
		guard currentJob?.appUUID != job.appUUID else { return }
		guard !queue.contains(where: { $0.appUUID == job.appUUID }) else { return }

		queue.append(job)

		if !_isRunning {
			_isRunning = true
			Task(priority: .userInitiated) { await _run() }
		}
	}

	// MARK: - Queue processing

	private func _run() async {
		defer { _isRunning = false }

		while let job = queue.first {
			queue.removeFirst()
			currentJob = job
			await _process(job)
			currentJob = nil
			currentPhase = ""
			suppressedJobs.remove(job.id)
			SourceAccessManager.shared.cleanupDeletedSubscriptions()
            UpdateManager.shared.sourceAvailabilityChanged(localApps: AppOperations.packages())
            AutoUpdateManager.shared.updateBadgeFromState()
            AppOperations.resumeDeferredUpdates()
			completedCount += 1
		}
	}

	private func _process(_ job: Job) async {
		guard let app = _resolveApp(uuid: job.appUUID), AppOperations.isAllowed(app), !suppressedJobs.contains(job.id) else { return }

		if job.installOnly {
			if let signed = app as? Signed {
				await _attemptSilentInstall(signed)
				AutoUpdateManager.shared.updateBadgeFromState()
			}
			return
		}

		let options = job.options ?? OptionsManager.shared.options
		let certificate = job.certificate ?? _certificate(for: app, options: options)
		if let error = AppOperations.signingError(for: app, certificate: certificate, targetIdentifier: options.appIdentifier) {
			lastErrorMessage = error
			if let id = app.identifier { installErrors[id] = error }
			return
		}
		currentPhase = "正在签名"

		if certificate == nil && options.signingOption == .default {
			lastErrorMessage = .localized("No valid certificate available for automatic signing.")
            if let id = job.appIdentifier ?? app.identifier { installErrors[id] = lastErrorMessage }
			AutoUpdateManager.shared.notify(
				title: .localized("Signing Failed"),
				body: .localized("%@ could not be signed automatically. Import a certificate in Settings.", arguments: job.appName ?? .localized("App")),
				identifier: "signos.sign.failed.\(job.appUUID)"
			)
			return
		}

		var signingError: Error?
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			FR.signPackageFile(app, using: options, icon: nil, certificate: certificate) { error in
				signingError = error
				continuation.resume()
			}
		}

		if let signingError {
			lastErrorMessage = signingError.localizedDescription
            if let id = app.identifier { installErrors[id] = signingError.localizedDescription }
            if job.reason == .renewal {
                let ids = UserDefaults.standard.stringArray(forKey: "SignOs.renewedUUIDs") ?? []
                UserDefaults.standard.set(ids.filter { $0 != job.appUUID }, forKey: "SignOs.renewedUUIDs")
            }
			ActivityLog.shared.log(.failed, app: job.appName ?? .localized("App"), detail: signingError.localizedDescription)

			// one automatic retry — transient failures (locks, disk spikes) recover
			if job.retryCount < 1 && AppOperations.isAllowed(app) && !suppressedJobs.contains(job.id) {
				var retry = Job(
					appUUID: job.appUUID,
					reason: job.reason,
					appIdentifier: job.appIdentifier,
					appName: job.appName,
					certificate: job.certificate,
					options: job.options
				)
				retry.retryCount = job.retryCount + 1
				enqueue(job: retry)
				return
			}

			AutoUpdateManager.shared.notify(
				title: .localized("Couldn't Install %@", arguments: job.appName ?? .localized("App")),
				body: .localized("Open SignOs and try again."),
				identifier: "signos.failed.\(job.appUUID)"
			)
			AutoUpdateManager.shared.updateBadgeFromState()
			return
		}

		guard AppOperations.isAllowed(app), !suppressedJobs.contains(job.id) else { return }
		guard let identifier = options.appIdentifier ?? job.appIdentifier ?? app.identifier else { return }

		guard let newest = AppOperations.signedResult(for: app) ?? _signedApps().filter({ $0.identifier == identifier }).max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) else {
			lastErrorMessage = .localized("Signing did not produce a new app entry.")
			return
		}

        let signedApps = _signedApps().filter { $0.identifier == newest.identifier }
		if let uuid = newest.uuid {
			InstallPackageRetention.shared.schedule(
				for: uuid,
				signed: signedApps.filter { $0.uuid != uuid }.compactMap(\.uuid),
				imported: app.isSigned ? [] : [job.appUUID]
			)
		}

		switch job.reason {
		case .renewal:
			ActivityLog.shared.log(.renewed, app: newest.name ?? identifier)
		default:
			ActivityLog.shared.log(.updated, app: newest.name ?? identifier, detail: newest.version)
		}

		if let uuid = app.uuid { UpdateManager.shared.dismissUpdate(withLocalUUID: uuid) }
		await _attemptSilentInstall(newest)
		AutoUpdateManager.shared.updateBadgeFromState()
	}

	// MARK: - Install

	/// App Store-style finishing move: after signing, the install happens
	/// with the least friction the active method allows. Paired-device
	/// installs are fully silent; local-server installs either fire the
	/// system prompt immediately (app in foreground) or present a
	/// "tap to install" notification that completes on open.
	private func _attemptSilentInstall(_ app: Signed) async {
		guard AppOperations.isAllowed(app), currentJob.map({ !suppressedJobs.contains($0.id) }) ?? true else { return }
		Storage.shared.protectPackagesAwaitingInstallation(for: app)
		currentPhase = "正在安装"
		if let identifier = app.identifier { installErrors.removeValue(forKey: identifier) }
		let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
		guard method == 0 || method == 1 else { return }

		// charging-only preference: hold the install until power is connected
		if UserDefaults.standard.object(forKey: "SignOs.installChargingOnly") as? Bool ?? false {
			let state = UIDevice.current.batteryState
			guard state == .charging || state == .full else {
				AutoUpdateManager.shared.notify(
					title: .localized("%@ is waiting for power", arguments: app.name ?? .localized("App")),
					body: .localized("Connect your device to a charger to finish installing."),
					identifier: "signos.charging.\(app.uuid ?? UUID().uuidString)"
				)
				return
			}
		}

		ArchiveHandler.fastestCompressionOverride = true
		defer { ArchiveHandler.fastestCompressionOverride = false }

		do {
			if method == 1 {
				let viewModel = InstallerStatusViewModel(isIdevice: true)
				let handler = ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				let packageUrl = try await handler.archive()

				let proxy = InstallationProxy(viewModel: viewModel)
				guard AppOperations.isAllowed(app), currentJob.map({ !suppressedJobs.contains($0.id) }) ?? true else { return }
				try await proxy.install(at: packageUrl, suspend: false)
				Storage.shared.finishInstallCleanup(for: app)
				if let uuid = app.uuid { confirmedInstallUUIDs.insert(uuid) }

				ActivityLog.shared.log(.installed, app: app.name ?? .localized("App"))

				AutoUpdateManager.shared.notify(
					title: .localized("Installed %@", arguments: app.name ?? .localized("App")),
					body: .localized("The app is ready on your home screen."),
					identifier: "signos.installed.\(app.uuid ?? UUID().uuidString)"
				)
			} else {
				try await _serverInstall(app)
			}
		} catch {
            Self.releaseInstaller(app: app)
			lastErrorMessage = error.localizedDescription
			if let identifier = app.identifier { installErrors[identifier] = error.localizedDescription }
			ActivityLog.shared.log(.failed, app: app.name ?? .localized("App"), detail: error.localizedDescription)
			AutoUpdateManager.shared.notify(
				title: .localized("Couldn't Install %@", arguments: app.name ?? .localized("App")),
				body: .localized("Open SignOs to try again."),
				identifier: "signos.failed.\(app.uuid ?? UUID().uuidString)"
			)
		}
	}

	private func _serverInstall(_ app: Signed) async throws {
		let viewModel = InstallerStatusViewModel(isIdevice: false)
		let handler = ArchiveHandler(app: app, viewModel: viewModel)
		try await handler.move()
		let packageUrl = try await handler.archive()

		guard AppOperations.isAllowed(app), currentJob.map({ !suppressedJobs.contains($0.id) }) ?? true else { return }
		let installer = try ServerInstaller(app: app, viewModel: viewModel)
		installer.packageUrl = packageUrl
		Self._retainInstaller(installer, app: app, viewModel: viewModel)

		if UIApplication.shared.applicationState == .active {
			if installer.getServerMethod() == 1 {
				guard let presenter = UIApplication.topViewController(),
					!(presenter is SFSafariViewController), !presenter.isBeingDismissed else {
					throw NSError(domain: "SignOs.Install", code: 1, userInfo: [
						NSLocalizedDescriptionKey: String.localized("Couldn't show the installation page. Tap Install to try again.")
					])
				}
				let browser = InstallationBrowserPresentation(url: installer.pageEndpoint, viewModel: viewModel) {
					Self.installBrowsers.removeValue(forKey: installer.id)
				}
				Self.installBrowsers[installer.id] = browser
				browser.present(from: presenter)
			} else {
				guard let url = URL(string: installer.iTunesLink), await UIApplication.shared.open(url) else {
					throw NSError(domain: "SignOs.Install", code: 2, userInfo: [
						NSLocalizedDescriptionKey: String.localized("iOS did not accept the installation request. Check Settings > Installation, then tap Install to try again.")
					])
				}
			}
		} else if let uuid = app.uuid {
			AutoUpdateManager.shared.notify(
				title: .localized("%@ is ready", arguments: app.name ?? .localized("App")),
				body: .localized("Tap to install it now."),
				identifier: "signos.install.\(uuid)",
				category: "SIGNOS_INSTALL"
			)
		}
	}

    private static func releaseInstaller(app: Signed, token: String? = nil) {
        guard let uuid = app.uuid, let active = installLeases[uuid], token == nil || active == token else { return }
        installLeases.removeValue(forKey: uuid)
        installObservers.removeValue(forKey: active)
        SourceAccessManager.shared.endUse(app)
    }

    private static func _retainInstaller(_ installer: ServerInstaller, app: Signed, viewModel: InstallerStatusViewModel) {
        _liveInstallers.append(installer)
        let token = UUID().uuidString
        if UIApplication.shared.applicationState == .active, let uuid = app.uuid {
            installLeases[uuid] = token
            SourceAccessManager.shared.beginUse(app)
            installObservers[token] = viewModel.$status.sink { status in
                switch status {
                case .completed, .broken:
                    Task { @MainActor in releaseInstaller(app: app, token: token) }
                default: break
                }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            releaseInstaller(app: app, token: token)
            _liveInstallers.removeAll { $0 === installer }
        }
    }

	/// Fires the pending install when the user opens SignOs from the
	/// "tap to install" notification.
	private func _handleInstallRequest(uuid: String) async {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		guard let app = (try? Storage.shared.context.fetch(request))?.first else { return }

        enqueueInstall(app: app)
	}

	// MARK: - Certificate selection

	private func _certificate(for app: AppInfoPresentable, options: Options) -> CertificatePair? {
        AppOperations.certificate(for: app)
	}

	// MARK: - Fetch helpers

	private func _resolveApp(uuid: String) -> (any AppInfoPresentable)? {
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		if let signed = (try? Storage.shared.context.fetch(signedRequest))?.first {
			return signed
		}

		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
		if let imported = (try? Storage.shared.context.fetch(importedRequest))?.first {
			return imported
		}

		return nil
	}

	private func _signedApps() -> [Signed] {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
}
