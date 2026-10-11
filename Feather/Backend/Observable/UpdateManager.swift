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
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	
	@Published private(set) var checkIssues: [String] = []
	
	private let session: URLSession

	init(session: URLSession = .shared) { self.session = session }
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
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
			updates = _applySkips(_findUpdates(
				repositories: result.repositories, localApps: localApps, failedSources: result.failedSources
			))
			lastCheckedDate = Date()
			return true
		} catch {
			// A cancelled refresh is incomplete, not evidence that its sources were removed.
			let issue = String(localized: "Update check was cancelled. Tap Check to retry.")
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
			if held[update.bundleIdentifier] == true { return false }
			if skipped[update.bundleIdentifier] == update.remoteVersion { return false }
			return true
		}
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async throws -> (
		repositories: [(AltSource, ASRepository)], issues: [String], failedSources: [AltSource]
	) {
		var repositories: [(AltSource, ASRepository)] = []
		var issues: [String] = []
		var failedSources: [AltSource] = []
		
		for source in sources {
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
		var foundUpdates: [String: AppUpdate] = [:]
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		let metadataCandidates = localApps.compactMap { app -> SourceMetadataCandidate? in
			guard
				let uuid = app.uuid,
				let metadata = metadataByUUID[uuid]
			else {
				return nil
			}
			return SourceMetadataCandidate(appUUID: uuid, app: app, metadata: metadata)
		}
		
		for localApp in localApps {
			guard let localUUID = localApp.uuid else {
				continue
			}
			
			let sourceAppIdentifier: String
			let sourceAppVersion: String?
			let storedSourceURL: URL
			let storedRepositoryIdentifier: String?
			if let directMetadata = metadataByUUID[localUUID] {
				guard
					let metadataSourceAppIdentifier = directMetadata.sourceAppIdentifier,
					let metadataSourceURL = directMetadata.sourceRepositoryURL
				else {
					checkIssues.append("\(localApp.name ?? localUUID): \(String.localized("incomplete source metadata."))")
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = directMetadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
				storedRepositoryIdentifier = directMetadata.sourceRepositoryIdentifier
			} else if let fallback = _fallbackMetadataCandidate(
				for: localApp,
				localUUID: localUUID,
				candidates: metadataCandidates
			) {
				guard
					let metadataSourceAppIdentifier = fallback.metadata.sourceAppIdentifier,
					let metadataSourceURL = fallback.metadata.sourceRepositoryURL
				else {
					checkIssues.append("\(localApp.name ?? localUUID): \(String.localized("incomplete source metadata."))")
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = fallback.metadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
				storedRepositoryIdentifier = fallback.metadata.sourceRepositoryIdentifier
				Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				)
			} else if
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			{
				sourceAppIdentifier = localIdentifier
				sourceAppVersion = localApp.version
				storedSourceURL = localSourceURL
				storedRepositoryIdentifier = nil
			} else {
				continue
			}
			
			var matchedRepository = false
			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else {
					continue
				}
				
				guard SourceRepositoryIdentity.matches(
					storedURL: storedSourceURL,
					storedIdentifier: storedRepositoryIdentifier,
					currentURL: sourceURL,
					currentIdentifier: repository.id
				) else {
					continue
				}
				
				matchedRepository = true
				guard let remoteIndex = SourceSubscriptionIdentity.matchIndex(
					storedKey: sourceAppIdentifier,
					candidates: repository.apps.map { ($0.id ?? "", $0.sourceEntryIdentifier) },
					legacyPreferredIndex: repository.apps.firstIndex { $0.id == sourceAppIdentifier && $0.legacyDefault == true }
				) else {
					checkIssues.append("\(localApp.name ?? localUUID): \(String.localized("source subscription is missing or ambiguous."))")
					continue
				}
				let remoteApp = repository.apps[remoteIndex]
				// Persist the installed version, not the latest version from the repository.
				// This also repairs records on devices that already completed the v2 migration.
				if metadataByUUID[localUUID] == nil, storedRepositoryIdentifier == nil,
					let identifier = remoteApp.id {
					Storage.shared.addSourceMetadata(
						for: localUUID, kind: localApp.isSigned ? .signed : .imported,
						provenance: SourceAppProvenance(
							sourceRepositoryURL: sourceURL, sourceRepositoryIdentifier: repository.id,
							sourceRepositoryName: repository.name,
							sourceAppIdentifier: SourceSubscriptionIdentity.key(bundleIdentifier: identifier, subscriptionID: remoteApp.sourceEntryIdentifier),
							sourceAppName: localApp.name, sourceAppVersion: sourceAppVersion,
							sourceAppVersionDate: nil, sourceAppDownloadURL: nil
						)
					)
				}
				
				guard let remoteVersion = remoteApp.currentVersion, !remoteVersion.isEmpty else {
					checkIssues.append("\(localApp.name ?? localUUID): \(String.localized("source version is missing."))")
					continue
				}
				
				guard remoteVersion != sourceAppVersion else {
					continue
				}
				
				guard let downloadURL = remoteApp.currentDownloadUrl else {
					checkIssues.append("\(localApp.name ?? localUUID): \(String.localized("update download URL is missing."))")
					continue
				}
				
				guard let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				) else {
					continue
				}
				
				foundUpdates[localUUID] = AppUpdate(
					id: localUUID,
					localUUID: localUUID,
					localVersion: sourceAppVersion ?? localApp.version,
					remoteVersion: remoteVersion,
					appName: remoteApp.currentName,
					bundleIdentifier: remoteApp.id ?? "",
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					sourceProvenance: provenance,
					whatsNew: remoteApp.currentAppVersion?.localizedDescription
				)
				break
			}
			let linkedSourceFailed = failedSources.contains { source in
				guard let url = source.sourceURL else { return false }
				return SourceRepositoryIdentity.matches(
					storedURL: storedSourceURL, storedIdentifier: storedRepositoryIdentifier,
					currentURL: url, currentIdentifier: source.identifier
				)
			}
			if !matchedRepository && !linkedSourceFailed {
				checkIssues.append("\(localApp.name ?? localUUID): \(String.localized("linked repository is unavailable. Refresh or restore its source in Sources."))")
			}
		}
		checkIssues = Array(Set(checkIssues)).sorted()
		return foundUpdates
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
