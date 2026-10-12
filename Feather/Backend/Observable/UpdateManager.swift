//
//  UpdateManager.swift
//  Feather
//
//  Created by Dominic on 24.05.2026.
//

import AltSourceKit
import CoreData
import Foundation

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceProvenance: SourceAppProvenance
	let whatsNew: String?
    var managedIdentifier: String? = nil
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var candidates: [String: [AppUpdate]] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	
	@Published private(set) var checkIssues: [String] = []
	
	private var repositorySnapshot: [(AltSource, ASRepository)] = []
    private var localSnapshot: [any AppInfoPresentable] = []
    private let session: URLSession

	init(session: URLSession = .shared) { self.session = session }
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}

	/// Prefer a retained signed package, then an imported package of this source version.
	/// Source versions can differ from the version inside the IPA or its signed copy.
	func downloadedApp(
		for update: AppUpdate,
		among localApps: [AppInfoPresentable],
		isPackageAvailable: (AppInfoPresentable) -> Bool
	) -> AppInfoPresentable? {
		let signedIdentifier = localApps.first { $0.uuid == update.localUUID }?.identifier ?? update.bundleIdentifier
		let matches = localApps.filter { app in
			guard let metadata = Storage.shared.sourceMetadata(for: app),
				let sourceURL = metadata.sourceRepositoryURL,
				metadata.sourceAppIdentifier == update.sourceProvenance.sourceAppIdentifier,
				metadata.sourceAppVersion == update.remoteVersion,
				app.identifier == (app.isSigned ? signedIdentifier : update.bundleIdentifier),
				SourceRepositoryIdentity.matches(
					storedURL: sourceURL, storedIdentifier: metadata.sourceRepositoryIdentifier,
					currentURL: update.sourceURL, currentIdentifier: update.sourceProvenance.sourceRepositoryIdentifier
				), isPackageAvailable(app)
			else { return false }
			return true
		}
		return matches.first { $0.isSigned } ?? matches.first
	}
	
	func hasUpdate(for app: ASRepository.App, sourceURL: URL?) -> Bool {
		guard let sourceURL, let identifier = app.id, let version = app.currentVersion else {
			return false
		}
		return updates.values.contains {
			$0.bundleIdentifier == identifier &&
			($0.sourceProvenance.sourceAppIdentifier == SourceSubscriptionIdentity.key(bundleIdentifier: identifier, subscriptionID: app.sourceEntryIdentifier) || app.sourceEntryIdentifier == nil) &&
			$0.remoteVersion == version &&
			_matchesStoredRepository(storedSourceURL: $0.sourceURL, sourceURL: sourceURL)
		}
	}

	@discardableResult
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable],
		synchronizeSources: @MainActor () async throws -> [String] = { [] },
		onSourcesSynchronized: @MainActor ([(AltSource, ASRepository)]) -> Void = { _ in }
	) async -> Bool {
		guard !isChecking else { return false }
		
		isChecking = true
		defer { isChecking = false }
		do {
			let synchronizationIssues = try await synchronizeSources()
			let result = try await _fetchRepositories(from: sources)
			try Task.checkCancellation()
			// Publish the freshly synchronized sources before comparing installed apps.
			// Both screens consume the same response; checking never downloads it again.
			onSourcesSynchronized(result.repositories)
			checkIssues = synchronizationIssues + result.issues
            repositorySnapshot = result.repositories
            localSnapshot = localApps
			updates = _applySkips(_findUpdates(
				repositories: result.repositories, localApps: localApps, failedSources: result.failedSources
			))
			lastCheckedDate = Date()
			return true
		} catch {
			// A cancelled refresh is incomplete, not evidence that its sources were removed.
			let issue = String(localized: "Update check was cancelled. Pull down to retry.")
			if !checkIssues.contains(issue) { checkIssues.append(issue) }
			return false
		}
	}

	// MARK: - Skips & Holds

	func dismissUpdate(withLocalUUID id: String) {
		updates.removeValue(forKey: id)
	}

	func isHeld(for identifier: String) -> Bool {
		let held = UserDefaults.standard.dictionary(forKey: "SignOs.heldApps") as? [String: Bool] ?? [:]
		return held[identifier] ?? false
	}

	func setHeld(_ held: Bool, for identifier: String) {
		var dict = UserDefaults.standard.dictionary(forKey: "SignOs.heldApps") as? [String: Bool] ?? [:]
		dict[identifier] = held
		UserDefaults.standard.set(dict, forKey: "SignOs.heldApps")
	}

	func skip(version: String, for identifier: String) {
		var dict = UserDefaults.standard.dictionary(forKey: "SignOs.skippedVersions") as? [String: String] ?? [:]
		dict[identifier] = version
		UserDefaults.standard.set(dict, forKey: "SignOs.skippedVersions")
	}

	func clearSkip(for identifier: String) {
		var dict = UserDefaults.standard.dictionary(forKey: "SignOs.skippedVersions") as? [String: String] ?? [:]
		dict.removeValue(forKey: identifier)
		UserDefaults.standard.set(dict, forKey: "SignOs.skippedVersions")
	}

	func skippedVersion(for identifier: String) -> String? {
		let skipped = UserDefaults.standard.dictionary(forKey: "SignOs.skippedVersions") as? [String: String] ?? [:]
		return skipped[identifier]
	}

	/// Removes held apps and skipped versions; a skipped version
	/// resurfaces automatically once something newer is published.
	private func _applySkips(_ found: [String: AppUpdate]) -> [String: AppUpdate] {
		let skipped = UserDefaults.standard.dictionary(forKey: "SignOs.skippedVersions") as? [String: String] ?? [:]
		let held = UserDefaults.standard.dictionary(forKey: "SignOs.heldApps") as? [String: Bool] ?? [:]

		return found.filter { entry in
			let update = entry.value
			if held[update.managedIdentifier ?? update.bundleIdentifier] == true { return false }
			if skipped[update.managedIdentifier ?? update.bundleIdentifier] == update.remoteVersion { return false }
			return true
		}
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async throws -> (
		repositories: [(AltSource, ASRepository)], issues: [String], failedSources: [AltSource]
	) {
		var repositories: [(AltSource, ASRepository)] = []
		var issues: [String] = []
		var failedSources: [AltSource] = []
		
		for source in sources where SourcePolicy.isEnabled(url: source.sourceURL, identifier: source.identifier) {
			try Task.checkCancellation()
			guard let url = source.sourceURL else {
				issues.append("\(source.name ?? .localized("Source")): \(String.localized("source URL is missing."))")
				continue
			}
			
			do {
				var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
				request.setValue("SignOs-App/1", forHTTPHeaderField: "User-Agent")
				let (data, response) = try await session.data(for: request)
				guard let response = response as? HTTPURLResponse else {
					throw URLError(.badServerResponse)
				}
				guard response.statusCode == 200 else {
					issues.append("\(source.name ?? url.host ?? url.absoluteString): HTTP \(response.statusCode)")
					failedSources.append(source)
					continue
				}
				let repository = try JSONDecoder().decode(ASRepository.self, from: data)
				repositories.append((source, repository))
			} catch {
				if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
					throw CancellationError()
				}
				issues.append("\(source.name ?? url.host ?? url.absoluteString): \(error.localizedDescription)")
				failedSources.append(source)
			}
		}
		return (repositories, issues, failedSources)
	}
	
	private func _findUpdates(
        repositories: [(AltSource, ASRepository)],
        localApps: [AppInfoPresentable],
        failedSources: [AltSource]
    ) -> [String: AppUpdate] {
        var found: [String: AppUpdate] = [:]
        var available: [String: [AppUpdate]] = [:]
        for application in AppInventory.applications(localApps) {
            let local = application.primary
            guard let uuid = local.uuid, let identifier = local.identifier else { continue }
            var metadata = Storage.shared.sourceMetadata(for: local)
            // Repair legacy signing records only when their retained provenance is unambiguous.
            if metadata == nil, local.isSigned {
                let matches = application.packages.filter { !$0.isSigned && $0.version == local.version && Storage.shared.sourceMetadata(for: $0) != nil }
                if matches.count == 1, let oldUUID = matches[0].uuid {
                    Storage.shared.copySourceMetadata(from: oldUUID, to: uuid, kind: .signed)
                    metadata = Storage.shared.sourceMetadata(for: local)
                }
            }
            if metadata == nil, let storedURL = local.source {
                for (source, repository) in repositories {
                    guard let url = source.sourceURL,
                        SourceRepositoryIdentity.matches(storedURL: storedURL, storedIdentifier: nil, currentURL: url, currentIdentifier: repository.id),
                        let index = SourceSubscriptionIdentity.matchIndex(storedKey: identifier,
                            candidates: repository.apps.map { ($0.id ?? "", $0.sourceEntryIdentifier) },
                            legacyPreferredIndex: repository.apps.firstIndex { $0.id == identifier && $0.legacyDefault == true }) else { continue }
                    let remote = repository.apps[index]
                    Storage.shared.addSourceMetadata(for: uuid, kind: local.isSigned ? .signed : .imported,
                        provenance: SourceAppProvenance(sourceRepositoryURL: url, sourceRepositoryIdentifier: repository.id,
                            sourceRepositoryName: repository.name, sourceAppIdentifier: SourceSubscriptionIdentity.key(bundleIdentifier: identifier, subscriptionID: remote.sourceEntryIdentifier),
                            sourceAppName: local.name, sourceAppVersion: local.version, sourceAppVersionDate: nil, sourceAppDownloadURL: nil))
                    metadata = Storage.shared.sourceMetadata(for: local)
                    break
                }
            }
            let bundle = SourceSubscriptionIdentity.bundleIdentifier(from: metadata?.sourceAppIdentifier ?? identifier)
            let baseline = metadata?.sourceAppVersion ?? local.version
            var choices: [AppUpdate] = []
            for (source, repository) in repositories {
                guard let url = source.sourceURL,
                    SourcePolicy.isEnabled(url: url, identifier: repository.id ?? source.identifier) else { continue }
                for remote in repository.apps where remote.id == bundle {
                    guard let version = remote.currentVersion, !version.isEmpty,
                        let downloadURL = remote.currentDownloadUrl,
                        let provenance = SourceAppProvenance(sourceURL: url, repository: repository, app: remote),
                        !SourcePolicy.isSubscriptionDeleted(url: url, identifier: repository.id, appIdentifier: provenance.sourceAppIdentifier)
                    else { continue }
                    choices.append(AppUpdate(id: uuid, localUUID: uuid, localVersion: local.version,
                        remoteVersion: version, appName: remote.currentName, bundleIdentifier: bundle,
                        downloadURL: downloadURL, sourceURL: url, sourceProvenance: provenance,
                        whatsNew: remote.currentAppVersion?.localizedDescription, managedIdentifier: identifier))
                }
            }
            var seen = Set<String>()
            choices = choices.filter { seen.insert($0.sourceProvenance.sourceVersionID).inserted }
            choices.sort {
                if let comparison = AppVersion.compare($0.remoteVersion, $1.remoteVersion), comparison != .orderedSame {
                    return comparison == .orderedDescending
                }
                return $0.sourceProvenance.sourceVersionID < $1.sourceProvenance.sourceVersionID
            }
            available[identifier] = choices
            let newer = choices.filter { candidate in
                guard let baseline else { return false }
                return AppVersion.compare(candidate.remoteVersion, baseline) == .orderedDescending
            }
            guard let first = newer.first else { continue }
            let tied = newer.filter { AppVersion.compare($0.remoteVersion, first.remoteVersion) == .orderedSame }
            let preference = (UserDefaults.standard.dictionary(forKey: "SignOs.preferredUpdateSources") as? [String: String])?[identifier]
            let preferred = tied.first { Self.preferenceKey($0) == preference }
            let current = tied.first { candidate in
                let provenance = candidate.sourceProvenance
                guard let storedURL = metadata?.sourceRepositoryURL ?? local.source else { return false }
                return metadata?.sourceAppIdentifier == provenance.sourceAppIdentifier && SourceRepositoryIdentity.matches(
                    storedURL: storedURL,
                    storedIdentifier: metadata?.sourceRepositoryIdentifier,
                    currentURL: candidate.sourceURL, currentIdentifier: provenance.sourceRepositoryIdentifier)
            }
            if let chosen = preferred ?? current ?? (tied.count == 1 ? first : nil) {
                found[uuid] = chosen
            } else {
                checkIssues.append("\(local.name ?? identifier)：多个来源提供相同版本，请在应用详情中选择一次来源。")
            }
        }
        candidates = available
        checkIssues = Array(Set(checkIssues)).sorted()
        return found
    }

    static func preferenceKey(_ update: AppUpdate) -> String {
        SourcePolicy.subscriptionKey(url: update.sourceURL, identifier: update.sourceProvenance.sourceRepositoryIdentifier,
            appIdentifier: update.sourceProvenance.sourceAppIdentifier)
    }

    func selectCandidate(_ update: AppUpdate, for identifier: String) {
        guard SourcePolicy.isEnabled(url: update.sourceURL, identifier: update.sourceProvenance.sourceRepositoryIdentifier) else { return }
        var preferences = UserDefaults.standard.dictionary(forKey: "SignOs.preferredUpdateSources") as? [String: String] ?? [:]
        preferences[identifier] = Self.preferenceKey(update)
        UserDefaults.standard.set(preferences, forKey: "SignOs.preferredUpdateSources")
        if AppVersion.compare(update.remoteVersion, update.localVersion ?? "") == .orderedDescending { updates[update.localUUID] = update }
    }

    private func eligible(_ update: AppUpdate) -> Bool {
        let origin = update.sourceProvenance
        return SourcePolicy.isEnabled(url: update.sourceURL, identifier: origin.sourceRepositoryIdentifier) &&
            !SourcePolicy.isSubscriptionDeleted(url: update.sourceURL, identifier: origin.sourceRepositoryIdentifier, appIdentifier: origin.sourceAppIdentifier)
    }

    func sourceAvailabilityChanged(localApps: [any AppInfoPresentable]? = nil) {
        if let localApps { localSnapshot = localApps }
        checkIssues = []
        updates = _applySkips(_findUpdates(repositories: repositorySnapshot, localApps: localSnapshot, failedSources: []))
    }

	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		SourceRepositoryIdentity.matches(
			storedURL: storedSourceURL, storedIdentifier: nil,
			currentURL: sourceURL, currentIdentifier: nil
		)
	}
	
	private func _fallbackMetadataCandidate(
		for localApp: AppInfoPresentable,
		localUUID: String,
		candidates: [SourceMetadataCandidate]
	) -> SourceMetadataCandidate? {
		guard
			localApp.isSigned,
			let localIdentifier = localApp.identifier,
			let localVersion = localApp.version
		else {
			return nil
		}
		
		return candidates.first {
			$0.appUUID != localUUID &&
			!$0.app.isSigned &&
			$0.app.identifier == localIdentifier &&
			$0.app.version == localVersion
		}
	}
}

private struct SourceMetadataCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let metadata: AppSourceMetadata
}
