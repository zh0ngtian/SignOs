//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI
import NimbleJSON
import CoreData

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	private let _dataService = NBFetchService()
	
	var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	@MainActor private var _revision = 0
	@MainActor private var _synchronizationTask: Task<Void, Never>?
	@Published private(set) var isSynchronizingSources = false
	@Published private(set) var sourceRefreshIssues: [String] = []

    /// Keep manual synchronization alive when SwiftUI cancels the refresh waiter.
    @MainActor
    func synchronizeAndRefreshSources() async {
        if let task = _synchronizationTask {
            await task.value
            return
        }
        let task = Task { @MainActor in
            defer {
                self._synchronizationTask = nil
                self.isSynchronizingSources = false
            }
            self.isSynchronizingSources = true
            self.sourceRefreshIssues = []
            // Do not let an older browsing fetch overwrite the manual refresh.
            self._revision += 1
            let sources = Storage.shared.getSources().filter { !$0.isDeleted }
            let enabled = sources.filter { SourcePolicy.isEnabled(url: $0.sourceURL, identifier: $0.identifier) }
            do {
                self.sourceRefreshIssues = try await SourceSynchronization.synchronizeManagedSources(enabled)
            } catch {
                self.sourceRefreshIssues = [error.localizedDescription]
            }
            for source in sources where !source.isDeleted && source.managedObjectContext != nil {
                do {
                    try await self.refreshSource(source)
                } catch {
                    self.sourceRefreshIssues.append("\(source.name ?? .localized("Source")): \(error.localizedDescription)")
                }
            }
        }
        _synchronizationTask = task
        await task.value
    }

	/// Replace the browsing cache with the exact snapshot used by the update check.
	@MainActor
	func applySynchronizedRepositories(_ repositories: [(AltSource, ASRepository)]) {
		_revision += 1
		var refreshed: [AltSource: ASRepository] = [:]
		var dates = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]
		var didUpdateIcon = false
		for (source, repository) in repositories {
			guard !source.isDeleted, source.managedObjectContext != nil else { continue }
			refreshed[source] = repository
			dates[source.identifier ?? ""] = Date()
			if source.iconURL != repository.currentIconURL {
				source.iconURL = repository.currentIconURL
				didUpdateIcon = true
			}
		}
		UserDefaults.standard.set(dates, forKey: "SignOs.sourceRefreshDates")
		sources = refreshed
		if didUpdateIcon { Storage.shared.saveContext() }
	}
	
    /// Refresh only this subscription, retaining its last successful data on failure.
    @MainActor
    func refreshSource(_ source: AltSource) async throws {
        guard let url = source.sourceURL else { throw URLError(.badURL) }
        let revision = _revision
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let repository = try JSONDecoder().decode(ASRepository.self, from: data)
        try Task.checkCancellation()
        guard _revision == revision, !source.isDeleted, source.managedObjectContext != nil else { return }
        source.iconURL = repository.currentIconURL
        Storage.shared.saveContext()
        var dates = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]
        dates[source.identifier ?? ""] = Date()
        UserDefaults.standard.set(dates, forKey: "SignOs.sourceRefreshDates")
        sources[source] = repository
    }

	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		if let task = await MainActor.run(body: { self._synchronizationTask }) { await task.value }
		guard isFinished else { return }
		
		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }
		
		// isfinished is used to prevent multiple fetches at the same time
		isFinished = false
		defer { isFinished = true }
		
		let revision = await MainActor.run {
			guard self._synchronizationTask == nil else { return nil as Int? }
			self.sources = [:]
			return self._revision as Int?
		}
		guard let revision else { return }
		
		let sourcesArray = Array(sources)
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			let batchResults = await withTaskGroup(of: (AltSource, ASRepository?).self, returning: [AltSource: ASRepository].self) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source, nil)
						}
						
						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repo):
									continuation.resume(returning: (source, repo))
								case .failure(_):
									continuation.resume(returning: (source, nil))
								}
							}
						}
					}
				}
				
				var results = [AltSource: ASRepository]()
				for await (source, repo) in group {
					if let repo {
						results[source] = repo
					}
				}
				return results
			}
			
			await MainActor.run {
				// An update check may have synchronized newer data while this fetch was running.
				guard self._revision == revision else { return }
				var didUpdateIcon = false
				for (source, repo) in batchResults {
					guard !source.isDeleted, source.managedObjectContext != nil else { continue }
					if source.iconURL != repo.currentIconURL {
						source.iconURL = repo.currentIconURL
						didUpdateIcon = true
					}
					var dates = UserDefaults.standard.dictionary(forKey: "SignOs.sourceRefreshDates") as? [String: Date] ?? [:]
                    dates[source.identifier ?? ""] = Date()
                    UserDefaults.standard.set(dates, forKey: "SignOs.sourceRefreshDates")
                    self.sources[source] = repo
				}
				if didUpdateIcon {
					Storage.shared.saveContext()
				}
			}
		}
	}
}
