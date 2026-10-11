// Compile the actual UpdateManager and metadata writer; only app storage setup is replaced.
import Foundation
import CoreData
import Combine
import Darwin

protocol AppInfoPresentable {
    var uuid: String? { get }
    var name: String? { get }
    var identifier: String? { get }
    var version: String? { get }
    var source: URL? { get }
    var isSigned: Bool { get }
}
struct LocalApp: AppInfoPresentable {
    var uuid: String? = "museum"
    var name: String? = "博物女神"
    var identifier: String? = "tech.zh0ngtian.MuseumMuse"
    var version: String? = "1.1.2"
    var source: URL? = URL(string: "https://yao-app-source.305301890.workers.dev/source.json")!
    var isSigned = true
}
struct AltSource {
    let sourceURL: URL?
    var name: String? = "Official"
    var identifier: String? = "tech.zh0ngtian.yao-app-source"
}

@objc(AppSourceMetadata)
final class AppSourceMetadata: NSManagedObject {
    @NSManaged var appUUID: String
    @NSManaged var appKind: String
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var sourceRepositoryURL: URL?
    @NSManaged var sourceRepositoryIdentifier: String?
    @NSManaged var sourceRepositoryName: String?
    @NSManaged var sourceAppIdentifier: String?
    @NSManaged var sourceAppName: String?
    @NSManaged var sourceAppVersion: String?
    @NSManaged var sourceAppVersionDate: Date?
    @NSManaged var sourceAppDownloadURL: URL?
    @NSManaged var sourceVersionID: String?
    static func fetchRequest() -> NSFetchRequest<AppSourceMetadata> { NSFetchRequest(entityName: "AppSourceMetadata") }
}
final class Storage {
    static let shared = Storage()
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    init() {
        let model = NSManagedObjectModel(contentsOf: Bundle.main.url(forResource: "Feather", withExtension: "momd")!)!
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context.persistentStoreCoordinator = coordinator
    }
    func saveContext() { try! context.save() }
    func reset() { getSourceMetadata().forEach(context.delete); saveContext() }
}

final class FixtureProtocol: URLProtocol {
    static var data = Data()
    static var status = 200
    static var error: URLError?
    static var onStart: (() -> Void)?
    static var waitForCancellation = false
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        Self.onStart?()
        if Self.waitForCancellation { return }
        if let error = Self.error {
            client!.urlProtocol(self, didFailWithError: error)
            return
        }
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Self.data)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct UpdateManagerRegression {
    @MainActor
    static func main() async throws {
        func checkpoint(_ message: String) { print("Update regression: \(message)"); fflush(stdout) }
        checkpoint("main started")
        let canonical = URL(string: "https://signos-source-aggregator.305301890.workers.dev/sources/yao.json")!
        let officialID = "tech.zh0ngtian.yao-app-source"
        let bundle = "tech.zh0ngtian.MuseumMuse"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let manager = UpdateManager(session: URLSession(configuration: configuration))
        let source = AltSource(sourceURL: canonical)
        let local = LocalApp()
        func fixture(_ apps: [[String: Any]], id: String = officialID) throws {
            FixtureProtocol.status = 200
            FixtureProtocol.data = try JSONSerialization.data(withJSONObject: ["identifier": id, "name": "Official", "apps": apps])
        }
        func app(version: String = "1.1.3", entry: String = "museum-primary", legacy: Bool = true) -> [String: Any] {
            ["bundleIdentifier": bundle, "name": "MuseumMuse", "iconURL": "https://example.com/icon.png", "appID": entry, "legacyDefault": legacy,
             "versions": [["version": version, "downloadURL": "https://example.com/museum.ipa", "size": 2603060]]]
        }
        UserDefaults.standard.removeObject(forKey: "SignOs.heldApps")
        UserDefaults.standard.removeObject(forKey: "SignOs.skippedVersions")
        UserDefaults.standard.set(true, forKey: "SignOs.cloudSourceMigration.v2")
        defer {
            UserDefaults.standard.removeObject(forKey: "SignOs.heldApps")
            UserDefaults.standard.removeObject(forKey: "SignOs.skippedVersions")
            UserDefaults.standard.removeObject(forKey: "SignOs.cloudSourceMigration.v2")
        }
        try fixture([app(), app(version: "9.0", entry: "museum-variant", legacy: false)])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        checkpoint("first legacy check completed")
        precondition(manager.updates["museum"]?.remoteVersion == "1.1.3", "Updates: \(manager.updates), issues: \(manager.checkIssues)")
        precondition(manager.updates["museum"]?.localVersion == "1.1.2")
        precondition(manager.checkIssues.isEmpty)
        let repaired = Storage.shared.sourceMetadata(for: "museum")!
        precondition(repaired.sourceRepositoryURL == canonical && repaired.sourceRepositoryIdentifier == officialID)
        precondition(repaired.sourceAppVersion == "1.1.2", "Repair must not record the remote version as installed")
        precondition(repaired.sourceAppIdentifier == SourceSubscriptionIdentity.key(bundleIdentifier: bundle, subscriptionID: "museum-primary"))
        precondition(FixtureProtocol.requests.last!.cachePolicy == .reloadIgnoringLocalCacheData)
        await manager.checkForUpdates(sources: [source], localApps: [local])
        checkpoint("repeat legacy check completed")
        precondition(manager.updates["museum"]?.remoteVersion == "1.1.3", "Repeat checks must retain the update after repair")

        let secondSource = AltSource(sourceURL: URL(string: "https://example.com/second-source.json")!)
        try fixture([app(version: "1.1.4")])
        let requestsBeforeSync = FixtureProtocol.requests.count
        var synchronized = false
        let syncCompleted = await manager.checkForUpdates(sources: [source, secondSource], localApps: [local]) { repositories in
            precondition(repositories.count == 2, "Synchronize every subscribed source, including sources without installed apps")
            precondition(FixtureProtocol.requests.count == requestsBeforeSync + 2, "Download each source only once")
            precondition(manager.updates["museum"]?.remoteVersion == "1.1.3", "Publish sources before comparing app versions")
            synchronized = true
        }
        precondition(syncCompleted && synchronized && manager.updates["museum"]?.remoteVersion == "1.1.4")
        try fixture([app()])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        checkpoint("all-source synchronization before comparison with one request per source passed")

        checkpoint("repeat check and metadata repair passed")
        let pendingUpdates = manager.updates
        let checkedDate = manager.lastCheckedDate
        FixtureProtocol.error = URLError(.cancelled)
        let cancelled = await manager.checkForUpdates(sources: [source], localApps: [local]) { _ in
            preconditionFailure("Cancellation must not publish a partial source synchronization")
        }
        precondition(!cancelled && !manager.isChecking)
        precondition(manager.updates == pendingUpdates, "Cancellation must retain pending updates")
        precondition(manager.lastCheckedDate == checkedDate, "Cancellation must not count as a completed check")
        precondition(manager.checkIssues.count == 1 && manager.checkIssues[0].contains("Tap Check"))
        precondition(!manager.checkIssues.contains { $0.contains("linked repository") })
        FixtureProtocol.error = nil
        let retryCompleted = await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(retryCompleted)
        precondition(manager.checkIssues.isEmpty, "Retry must clear cancellation")

        let retryDate = manager.lastCheckedDate
        FixtureProtocol.waitForCancellation = true
        var checkingTask: Task<Bool, Never>?
        FixtureProtocol.onStart = { checkingTask?.cancel() }
        checkingTask = Task { await manager.checkForUpdates(sources: [source, source], localApps: [local]) }
        let requestsBeforeCancellation = FixtureProtocol.requests.count
        let taskCompleted = await checkingTask!.value
        precondition(!taskCompleted && !manager.isChecking)
        precondition(manager.updates == pendingUpdates && manager.lastCheckedDate == retryDate)
        precondition(FixtureProtocol.requests.count == requestsBeforeCancellation + 1, "Cancelled checks must stop before fetching subsequent sources")
        precondition(!manager.checkIssues.contains { $0.contains("linked repository") })
        FixtureProtocol.onStart = nil
        FixtureProtocol.waitForCancellation = false
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.checkIssues.isEmpty && manager.updates == pendingUpdates)
        checkpoint("URLSession cancellation, in-flight task cancellation and retry passed")

        manager.setHeld(true, for: bundle)
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && manager.checkIssues.isEmpty)
        manager.setHeld(false, for: bundle)
        manager.skip(version: "1.1.3", for: bundle)
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && manager.checkIssues.isEmpty)
        try fixture([app(version: "1.1.4")])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates["museum"]?.remoteVersion == "1.1.4")
        manager.clearSkip(for: bundle)

        checkpoint("holds and skips passed")
        Storage.shared.reset()
        try fixture([app(legacy: false), app(entry: "other", legacy: false)])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && !manager.checkIssues.isEmpty)
        precondition(Storage.shared.sourceMetadata(for: "museum") == nil, "Ambiguous variants must not be backfilled")
        try fixture([app()], id: "unrelated.source")
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && !manager.checkIssues.isEmpty)
        precondition(Storage.shared.sourceMetadata(for: "museum") == nil)
        try fixture([app()])
        checkpoint("ambiguous and unrelated sources passed")
        FixtureProtocol.status = 503
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && !manager.checkIssues.isEmpty, "HTTP failures cannot claim a clean check")
        precondition(manager.checkIssues == ["Official: HTTP 503"], "A fetch failure must not claim the linked source was removed: \(manager.checkIssues)")
        FixtureProtocol.status = 200
        FixtureProtocol.data = Data("{broken json".utf8)
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && !manager.checkIssues.isEmpty)
        precondition(!manager.checkIssues.contains { $0.contains("linked repository") })
        try fixture([app(version: "1.1.2")])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && manager.checkIssues.isEmpty, "Successful retry must clear failures")
        precondition(Storage.shared.sourceMetadata(for: "museum")?.sourceAppVersion == "1.1.2")
        await manager.checkForUpdates(sources: [], localApps: [local])
        precondition(manager.checkIssues.contains { $0.contains("linked repository") }, "A removed source must still be reported")
        checkpoint("HTTP/JSON failures and retry passed")
        print("UpdateManagerRegression passed: migrated legacy record, durable local version, variants, holds/skips, cancellation, HTTP/JSON failures, removed source and retry")
    }
}
