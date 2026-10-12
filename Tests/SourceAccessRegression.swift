import Foundation

protocol AppInfoPresentable { var uuid: String? { get }; var identifier: String? { get }; var source: URL? { get } }
struct Package: AppInfoPresentable { let uuid: String?; let identifier: String?; let source: URL? }
struct AltSource { let sourceURL: URL?; let identifier: String? }
struct Metadata { let sourceRepositoryURL: URL?; let sourceRepositoryIdentifier: String?; let sourceAppIdentifier: String?; var appUUID: String? }
struct SourceAppProvenance { let sourceRepositoryURL: URL; let sourceRepositoryIdentifier: String?; let sourceAppIdentifier: String }
struct Download { let id: String; let sourceProvenance: SourceAppProvenance? }
@MainActor final class DownloadManager {
    static let shared = DownloadManager(); var downloads: [Download] = []
    func cancelDownload(_ download: Download) { downloads.removeAll { $0.id == download.id } }
}
@MainActor final class Storage {
    static let shared = Storage(); var apps: [Package] = []; var metadata: [String: Metadata] = [:]; var removed: [String] = []
    func sourceMetadata(for app: any AppInfoPresentable) -> Metadata? { app.uuid.flatMap { metadata[$0] } }
    func getSourceMetadata() -> [Metadata] { metadata.map { key, value in var item = value; item.appUUID = key; return item } }
    func deleteSourceMetadata(for uuid: String?) { if let uuid { metadata.removeValue(forKey: uuid) } }
    func deleteApp(for app: any AppInfoPresentable) { let uuid = app.uuid!; apps.removeAll { $0.uuid == uuid }; metadata.removeValue(forKey: uuid); removed.append(uuid) }
}
@MainActor enum AppOperations {
    static func packages() -> [any AppInfoPresentable] { Storage.shared.apps }
    static func resumeDeferredUpdates() {}
}
@MainActor final class AutoSignManager {
    struct Job { let appUUID: String }
    static let shared = AutoSignManager(); var queue: [Package] = []; var currentJob: Job?; var suppressed: [String] = []
    func cancelPending(where predicate: (any AppInfoPresentable) -> Bool) {
        queue.removeAll(where: predicate)
        if let uuid = currentJob?.appUUID, let app = Storage.shared.apps.first(where: { $0.uuid == uuid }), predicate(app) { suppressed.append(uuid) }
    }
}
@MainActor final class UpdateManager {
    static let shared = UpdateManager(); var changed = 0
    func sourceAvailabilityChanged(localApps: [any AppInfoPresentable]? = nil) { changed += 1 }
}
@MainActor final class AutoUpdateManager {
    static let shared = AutoUpdateManager()
    func updateBadgeFromState() {}
    func checkNow(notifyWhenClean: Bool, syncManagedSources: Bool) async {}
}

@main struct SourceAccessRegression {
    @MainActor static func main() {
        let keys = ["SignOs.disabledSources", "SignOs.deletedSubscriptions"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let a = AltSource(sourceURL: URL(string: "https://example.com/a.json")!, identifier: "source.a")
        let b = AltSource(sourceURL: URL(string: "https://example.com/b.json")!, identifier: "source.b")
        let bundle = "com.example.app"
        let appKey = SourceSubscriptionIdentity.key(bundleIdentifier: bundle, subscriptionID: "entry.a")
        let a1 = Package(uuid: "a1", identifier: bundle, source: a.sourceURL)
        let a2 = Package(uuid: "a2", identifier: bundle, source: a.sourceURL)
        let b1 = Package(uuid: "b1", identifier: bundle, source: b.sourceURL)
        let manual = Package(uuid: "manual", identifier: bundle, source: nil)
        Storage.shared.apps = [a1, a2, b1, manual]
        for app in [a1, a2] { Storage.shared.metadata[app.uuid!] = Metadata(sourceRepositoryURL: a.sourceURL, sourceRepositoryIdentifier: a.identifier, sourceAppIdentifier: appKey) }
        Storage.shared.metadata[b1.uuid!] = Metadata(sourceRepositoryURL: b.sourceURL, sourceRepositoryIdentifier: b.identifier, sourceAppIdentifier: SourceSubscriptionIdentity.key(bundleIdentifier: bundle, subscriptionID: "entry.b"))
        let access = SourceAccessManager.shared
        AutoSignManager.shared.queue = [a2, b1, manual]
        AutoSignManager.shared.currentJob = .init(appUUID: a1.uuid!)
        DownloadManager.shared.downloads = [Download(id: "a", sourceProvenance: .init(sourceRepositoryURL: a.sourceURL!, sourceRepositoryIdentifier: a.identifier, sourceAppIdentifier: appKey)), Download(id: "b", sourceProvenance: .init(sourceRepositoryURL: b.sourceURL!, sourceRepositoryIdentifier: b.identifier, sourceAppIdentifier: "other"))]
        access.beginUse(a1)
        access.setEnabled(false, for: a)
        precondition(!access.isEnabled(a) && access.isEnabled(b))
        precondition(Storage.shared.apps.count == 4 && Storage.shared.removed.isEmpty, "Disabling keeps every archive")
        precondition(DownloadManager.shared.downloads.map(\.id) == ["b"])
        precondition(AutoSignManager.shared.queue.map(\.uuid) == [b1.uuid, manual.uuid])
        precondition(access.wasSuppressed(a1.uuid) && AutoSignManager.shared.suppressed == [a1.uuid!])
        access.setEnabled(true, for: a)
        precondition(access.isEnabled(a) && access.wasSuppressed(a1.uuid), "Reenabling must not resume an interrupted job")
        access.deleteSubscription(url: a.sourceURL!, identifier: a.identifier, bundle: bundle, subscriptionID: "entry.a")
        precondition(Storage.shared.apps.map(\.uuid) == [a1.uuid, b1.uuid, manual.uuid], "Busy input is deferred; unrelated/manual packages survive")
        let result = Package(uuid: "result", identifier: bundle, source: a.sourceURL)
        Storage.shared.apps.append(result); Storage.shared.metadata[result.uuid!] = Storage.shared.metadata[a1.uuid!]
        AutoSignManager.shared.currentJob = nil
        access.endUse(a1)
        precondition(Storage.shared.apps.map(\.uuid) == [b1.uuid, manual.uuid], "Cleanup includes a late signing result")
        precondition(Set(Storage.shared.removed) == [a1.uuid!, a2.uuid!, result.uuid!])
        precondition(SourcePolicy.isSubscriptionDeleted(url: a.sourceURL, identifier: a.identifier, appIdentifier: appKey))
        precondition(!SourcePolicy.isSubscriptionDeleted(url: b.sourceURL, identifier: b.identifier, appIdentifier: "other"))
        print("SourceAccessRegression passed: disable/enable, scoped cancellation, retained archives, delayed deletion and late signing results")
    }
}
