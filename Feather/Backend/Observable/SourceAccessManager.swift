import Foundation
import CoreData
import Combine

@MainActor
final class SourceAccessManager: ObservableObject {
    static let shared = SourceAccessManager()
    @Published private(set) var revision = 0
    private var activePackages: [String: String] = [:]
    private var suppressedUses = Set<String>()
    private(set) var signedResults: [String: String] = [:]
    func recordSignedResult(input: String?, output: String) { if let input { signedResults[input] = output } }
    func wasSuppressed(_ uuid: String?) -> Bool { uuid.map { suppressedUses.contains($0) } ?? false }
    private func suppressActive(where matches: (any AppInfoPresentable) -> Bool) {
        for app in AppOperations.packages() where isInUse(app.uuid) && matches(app) {
            if let uuid = app.uuid { suppressedUses.insert(uuid) }
        }
    }
    func beginUse(_ app: any AppInfoPresentable) { if let uuid = app.uuid { activePackages[uuid] = app.identifier ?? uuid; suppressedUses.remove(uuid); revision += 1 } }
    func endUse(_ app: any AppInfoPresentable) {
        if let uuid = app.uuid { activePackages.removeValue(forKey: uuid); revision += 1 }
        cleanupDeletedSubscriptions()
        AppOperations.resumeDeferredUpdates()
    }
    func isInUse(_ uuid: String?) -> Bool { uuid.map { activePackages[$0] != nil } ?? false }

    func hasActiveApplication(_ identifier: String) -> Bool { activePackages.values.contains(identifier) }

    func isEnabled(_ source: AltSource) -> Bool {
        SourcePolicy.isEnabled(url: source.sourceURL, identifier: source.identifier)
    }

    func setEnabled(_ enabled: Bool, for source: AltSource) {
        let keys = SourcePolicy.keys(url: source.sourceURL, identifier: source.identifier)
        var disabled = Set(UserDefaults.standard.stringArray(forKey: "SignOs.disabledSources") ?? [])
        if enabled { disabled.subtract(keys) } else { disabled.formUnion(keys) }
        UserDefaults.standard.set(disabled.sorted(), forKey: "SignOs.disabledSources")
        if !enabled {
            suppressActive { app in
                if let metadata = Storage.shared.sourceMetadata(for: app) { return self.matches(metadata.sourceRepositoryURL, metadata.sourceRepositoryIdentifier, source.sourceURL, source.identifier) }
                return self.matches(app.source, nil, source.sourceURL, source.identifier)
            }
            for download in DownloadManager.shared.downloads where download.sourceProvenance.map({
                matches($0.sourceRepositoryURL, $0.sourceRepositoryIdentifier, source.sourceURL, source.identifier)
            }) == true { DownloadManager.shared.cancelDownload(download) }
            AutoSignManager.shared.cancelPending { app in
                guard let metadata = Storage.shared.sourceMetadata(for: app) else { return app.source == source.sourceURL }
                return self.matches(metadata.sourceRepositoryURL, metadata.sourceRepositoryIdentifier, source.sourceURL, source.identifier)
            }
        }
        revision += 1
        UpdateManager.shared.sourceAvailabilityChanged(localApps: AppOperations.packages())
        AutoUpdateManager.shared.updateBadgeFromState()
        if enabled { Task { await AutoUpdateManager.shared.checkNow(notifyWhenClean: false, syncManagedSources: true) } }
    }

    func deleteSubscription(url: URL, identifier: String?, bundle: String?, subscriptionID: String, allowLegacy: Bool = false) {
        var appKeys = Set<String>()
        if let bundle {
            appKeys.insert(SourceSubscriptionIdentity.key(bundleIdentifier: bundle, subscriptionID: subscriptionID))
            if allowLegacy { appKeys.insert(bundle) }
        }
        for metadata in Storage.shared.getSourceMetadata() {
            if matches(metadata.sourceRepositoryURL, metadata.sourceRepositoryIdentifier, url, identifier),
                let key = metadata.sourceAppIdentifier, key.hasSuffix(":" + subscriptionID) { appKeys.insert(key) }
        }
        for download in DownloadManager.shared.downloads {
            if let origin = download.sourceProvenance,
                matches(origin.sourceRepositoryURL, origin.sourceRepositoryIdentifier, url, identifier),
                origin.sourceAppIdentifier.hasSuffix(":" + subscriptionID) { appKeys.insert(origin.sourceAppIdentifier) }
        }
        var deleted = Set(UserDefaults.standard.stringArray(forKey: "SignOs.deletedSubscriptions") ?? [])
        for key in appKeys { deleted.formUnion(SourcePolicy.keys(url: url, identifier: identifier).map { $0 + "|" + key }) }
        UserDefaults.standard.set(deleted.sorted(), forKey: "SignOs.deletedSubscriptions")
        for download in DownloadManager.shared.downloads where download.sourceProvenance.map({
            appKeys.contains($0.sourceAppIdentifier) && matches($0.sourceRepositoryURL, $0.sourceRepositoryIdentifier, url, identifier)
        }) == true { DownloadManager.shared.cancelDownload(download) }
        let selected = appKeys
        AutoSignManager.shared.cancelPending { app in
            if let metadata = Storage.shared.sourceMetadata(for: app), let key = metadata.sourceAppIdentifier {
                return selected.contains(key) && self.matches(metadata.sourceRepositoryURL, metadata.sourceRepositoryIdentifier, url, identifier)
            }
            return app.identifier.map { selected.contains($0) } == true && self.matches(app.source, nil, url, identifier)
        }
        cleanupDeletedSubscriptions()
        UpdateManager.shared.sourceAvailabilityChanged(localApps: AppOperations.packages())
        revision += 1
    }

    func clearDeletedSubscriptions(url: URL, identifier: String?) {
        let prefixes = SourcePolicy.keys(url: url, identifier: identifier).map { $0 + "|" }
        let deleted = UserDefaults.standard.stringArray(forKey: "SignOs.deletedSubscriptions") ?? []
        UserDefaults.standard.set(deleted.filter { key in !prefixes.contains(where: key.hasPrefix) }, forKey: "SignOs.deletedSubscriptions")
        revision += 1
    }

    /// The tombstone also catches a signed result created after its subscription was deleted.
    func cleanupDeletedSubscriptions() {
        for app in AppOperations.packages() {
            let metadata = Storage.shared.sourceMetadata(for: app)
            guard let key = metadata?.sourceAppIdentifier ?? app.identifier,
                SourcePolicy.isSubscriptionDeleted(url: metadata?.sourceRepositoryURL ?? app.source, identifier: metadata?.sourceRepositoryIdentifier, appIdentifier: key),
                !isInUse(app.uuid), AutoSignManager.shared.currentJob?.appUUID != app.uuid else { continue }
            Storage.shared.deleteApp(for: app)
        }
        let existing = Set(AppOperations.packages().compactMap(\.uuid))
        for metadata in Storage.shared.getSourceMetadata() {
            guard let uuid = metadata.appUUID, !existing.contains(uuid), !isInUse(uuid),
                let key = metadata.sourceAppIdentifier,
                SourcePolicy.isSubscriptionDeleted(url: metadata.sourceRepositoryURL, identifier: metadata.sourceRepositoryIdentifier, appIdentifier: key) else { continue }
            Storage.shared.deleteSourceMetadata(for: metadata.appUUID)
        }
    }

    private func matches(_ a: URL?, _ ai: String?, _ b: URL?, _ bi: String?) -> Bool {
        guard let a, let b else { return false }
        return SourceRepositoryIdentity.matches(storedURL: a, storedIdentifier: ai, currentURL: b, currentIdentifier: bi)
    }
}
