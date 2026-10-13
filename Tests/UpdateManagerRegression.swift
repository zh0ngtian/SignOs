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
    var date: Date? { get }
}
struct LocalApp: AppInfoPresentable {
    var uuid: String? = "museum"
    var name: String? = "博物女神"
    var identifier: String? = "tech.zh0ngtian.MuseumMuse"
    var version: String? = "1.1.2"
    var source: URL? = URL(string: "https://yao-app-source.305301890.workers.dev/source.json")!
    var isSigned = true
    var date: Date? = Date(timeIntervalSince1970: 100)
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
    static var response: ((URLRequest) -> (Data, Int))?
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
        let (data, status) = Self.response?(request) ?? (Self.data, Self.status)
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
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
        // Source order and publication dates must not determine semantic version order.
        var historyApp = app(version: "1.12.0")
        historyApp["versions"] = [
            ["version": "1.12.0", "date": "2026-10-10T08:30:00Z", "localizedDescription": "最新改进", "downloadURL": "https://example.com/latest.ipa"],
            ["version": "1.3.0", "date": "2026-10-12T00:00:00Z", "localizedDescription": "中间改进"],
            ["version": "1.3.0", "localizedDescription": "重复记录不能重复显示"],
            ["version": "1.10.0", "localizedDescription": "  \n "],
            ["version": "1.12.0-beta.1", "localizedDescription": "测试版改进"],
            ["version": "1.1.2", "localizedDescription": "当前版本不能重复显示"],
            ["version": "1.0.0", "localizedDescription": "旧版不能显示"],
            ["version": "2.0.0", "localizedDescription": "目标之后的版本不能显示"],
            ["version": "unknown", "localizedDescription": "不可比较版本不能混入"]
        ]
        var otherSubscription = app(version: "1.11.0", entry: "other-subscription", legacy: false)
        otherSubscription["versions"] = [["version": "1.11.0", "localizedDescription": "其他订阅不能混入", "downloadURL": "https://example.com/other.ipa"]]
        try fixture([historyApp, otherSubscription])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        let history = manager.updates["museum"]!.releaseHistory
        precondition(history.map(\.version) == ["1.12.0", "1.12.0-beta.1", "1.10.0", "1.3.0"], "Show the complete upgrade range in semantic descending order")
        precondition(history.first?.notes == "最新改进" && history.last?.notes == "中间改进")
        precondition(history[2].notes == nil && history[2].date == nil, "Keep releases with missing notes or dates")
        precondition(history[0].date == ISO8601DateFormatter().date(from: "2026-10-10T08:30:00Z"))
        precondition(manager.candidates[bundle]!.first { $0.remoteVersion == "1.11.0" }!.releaseHistory.first?.notes == "其他订阅不能混入")
        // The source page obtains a package from provenance alone, without release notes.
        // Selecting that provisional candidate must preserve the checked source snapshot.
        let checkedUpdate = manager.updates["museum"]!
        let provisional = AppUpdate(id: checkedUpdate.id, localUUID: checkedUpdate.localUUID,
            localVersion: checkedUpdate.localVersion, remoteVersion: checkedUpdate.remoteVersion,
            appName: checkedUpdate.appName, bundleIdentifier: checkedUpdate.bundleIdentifier,
            downloadURL: checkedUpdate.downloadURL, sourceURL: checkedUpdate.sourceURL,
            sourceProvenance: checkedUpdate.sourceProvenance, whatsNew: nil,
            releaseHistory: [UpdateRelease(version: checkedUpdate.remoteVersion, date: nil, notes: nil)],
            managedIdentifier: checkedUpdate.managedIdentifier)
        manager.selectCandidate(provisional, for: bundle)
        precondition(manager.updates["museum"]?.releaseHistory == history, "Source-page updates must preserve the complete checked history")
        precondition(manager.updates["museum"]?.whatsNew == "最新改进", "Preserve the checked latest release notes as well")
        UserDefaults.standard.removeObject(forKey: "SignOs.preferredUpdateSources")
        let stored = Storage.shared.sourceMetadata(for: "museum")!
        stored.sourceAppVersion = "1.3.0"
        Storage.shared.saveContext()
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates["museum"]!.releaseHistory.map(\.version) == ["1.12.0", "1.12.0-beta.1", "1.10.0"], "Use retained source version rather than IPA version as the baseline")
        try fixture([app()])
        stored.sourceAppVersion = "1.1.2"
        Storage.shared.saveContext()
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates["museum"]!.releaseHistory.map(\.version) == ["1.1.3"], "Single step updates still show one release")
        var legacyApp = app()
        legacyApp.removeValue(forKey: "versions")
        legacyApp["version"] = "1.1.3"
        legacyApp["downloadURL"] = "https://example.com/legacy.ipa"
        legacyApp["versionDate"] = "2026-10-09T09:00:00Z"
        legacyApp["versionDescription"] = "旧格式更新说明"
        try fixture([legacyApp])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        let legacyHistory = manager.updates["museum"]!.releaseHistory
        precondition(legacyHistory.count == 1 && legacyHistory[0].notes == "旧格式更新说明" && legacyHistory[0].date != nil)
        Storage.shared.reset()
        checkpoint("upgrade release history completed")
        try fixture([app(), app(version: "9.0", entry: "museum-variant", legacy: false)])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        checkpoint("first legacy check completed")
        precondition(manager.updates["museum"]?.remoteVersion == "9.0", "Updates: \(manager.updates), issues: \(manager.checkIssues)")
        precondition(manager.updates["museum"]?.localVersion == "1.1.2")
        precondition(manager.checkIssues.isEmpty)
        let repaired = Storage.shared.sourceMetadata(for: "museum")!
        precondition(repaired.sourceRepositoryURL == canonical && repaired.sourceRepositoryIdentifier == officialID)
        precondition(repaired.sourceAppVersion == "1.1.2", "Repair must not record the remote version as installed")
        precondition(repaired.sourceAppIdentifier == SourceSubscriptionIdentity.key(bundleIdentifier: bundle, subscriptionID: "museum-primary"))
        precondition(FixtureProtocol.requests.last!.cachePolicy == .reloadIgnoringLocalCacheData)
        await manager.checkForUpdates(sources: [source], localApps: [local])
        checkpoint("repeat legacy check completed")
        precondition(manager.updates["museum"]?.remoteVersion == "9.0", "Repeat checks must retain the update after repair")

        let secondSource = AltSource(sourceURL: URL(string: "https://example.com/second-source.json")!)
        try fixture([app(version: "1.1.4")])
        let requestsBeforeSync = FixtureProtocol.requests.count
        var synchronized = false
        var remoteSynchronized = false
        let syncCompleted = await manager.checkForUpdates(sources: [source, secondSource], localApps: [local], synchronizeSources: {
            precondition(FixtureProtocol.requests.count == requestsBeforeSync, "Remote synchronization must finish before downloading feeds")
            remoteSynchronized = true
            return []
        }) { repositories in
            precondition(remoteSynchronized)
            precondition(repositories.count == 2, "Synchronize every subscribed source, including sources without installed apps")
            precondition(FixtureProtocol.requests.count == requestsBeforeSync + 2, "Download each source only once")
            precondition(manager.updates["museum"]?.remoteVersion == "9.0", "Publish sources before comparing app versions")
            synchronized = true
        }
        precondition(syncCompleted && synchronized && manager.updates["museum"]?.remoteVersion == "1.1.4")
        try fixture([app()])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        checkpoint("all-source synchronization before comparison with one request per source passed")

        checkpoint("repeat check and metadata repair passed")
        // A completed download persists independently of the transient download task.
        let update = manager.updates["museum"]!
        let imported = LocalApp(uuid: "downloaded", version: "ipa-version", isSigned: false)
        let signed = LocalApp(uuid: "signed-download", version: "signed-version")
        let clone = LocalApp(uuid: "clone", identifier: bundle + ".clone")
        for candidate in [imported, signed, clone] {
            Storage.shared.addSourceMetadata(for: candidate.uuid!, kind: candidate.isSigned ? .signed : .imported,
                                             provenance: update.sourceProvenance)
        }
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        func packageURL(_ app: AppInfoPresentable) -> URL { packageRoot.appendingPathComponent(app.uuid!) }
        func available(_ app: AppInfoPresentable) -> Bool { FileManager.default.fileExists(atPath: packageURL(app).path) }
        try Data("completed import".utf8).write(to: packageURL(imported))
        precondition(manager.downloadedApp(for: update, among: [local, imported], isPackageAvailable: available)?.uuid == imported.uuid,
                     "Reuse imported source version even if the IPA's own version differs")
        try Data("signed package".utf8).write(to: packageURL(signed))
        try Data("clone".utf8).write(to: packageURL(clone))
        precondition(manager.downloadedApp(for: update, among: [imported, clone, signed, local], isPackageAvailable: available)?.uuid == signed.uuid,
                     "Prefer a ready signed package and never install a cloned identity")
        let restarted = UpdateManager(session: URLSession(configuration: configuration))
        precondition(restarted.downloadedApp(for: update, among: [signed, imported, local], isPackageAvailable: available)?.uuid == signed.uuid,
                     "Reuse persists when the manager is recreated")
        func record(version: String = update.remoteVersion, entry: String = update.sourceProvenance.sourceAppIdentifier,
                    repositoryURL: URL = canonical, repositoryID: String? = officialID) {
            Storage.shared.addSourceMetadata(for: signed.uuid!, kind: .signed, provenance: SourceAppProvenance(
                sourceRepositoryURL: repositoryURL, sourceRepositoryIdentifier: repositoryID,
                sourceRepositoryName: "Official", sourceAppIdentifier: entry, sourceAppName: "MuseumMuse",
                sourceAppVersion: version, sourceAppVersionDate: nil,
                sourceAppDownloadURL: URL(string: "https://example.com/changed-delivery-url.ipa")!))
        }
        record()
        precondition(manager.downloadedApp(for: update, among: [signed], isPackageAvailable: available)?.uuid == signed.uuid,
                     "A delivery URL change must not redownload the same source version")
        record(repositoryURL: URL(string: "https://example.com/moved-source.json")!)
        precondition(manager.downloadedApp(for: update, among: [signed], isPackageAvailable: available)?.uuid == signed.uuid)
        record(version: "1.1.2")
        precondition(manager.downloadedApp(for: update, among: [signed], isPackageAvailable: available) == nil)
        record(entry: "different-subscription")
        precondition(manager.downloadedApp(for: update, among: [signed], isPackageAvailable: available) == nil)
        record(repositoryURL: URL(string: "https://example.com/unrelated-source.json")!, repositoryID: "unrelated")
        precondition(manager.downloadedApp(for: update, among: [signed], isPackageAvailable: available) == nil)
        record()
        try FileManager.default.removeItem(at: packageURL(signed))
        precondition(manager.downloadedApp(for: update, among: [signed, imported], isPackageAvailable: available)?.uuid == imported.uuid,
                     "Missing signed files fall back to the completed import")
        try FileManager.default.removeItem(at: packageURL(imported))
        precondition(manager.downloadedApp(for: update, among: [signed, imported, local], isPackageAvailable: available) == nil,
                     "Missing files must permit a fresh download")
        for candidate in [imported, signed, clone] { Storage.shared.deleteSourceMetadata(for: candidate.uuid) }
        checkpoint("download reuse: signed/imported, restart, source version, URL migration, variants, clones and missing files passed")
        let pendingUpdates = manager.updates
        let checkedDate = manager.lastCheckedDate
        FixtureProtocol.error = URLError(.cancelled)
        let cancelled = await manager.checkForUpdates(sources: [source], localApps: [local], onSourcesSynchronized: { _ in
            preconditionFailure("Cancellation must not publish a partial source synchronization")
        })
        precondition(!cancelled && !manager.isChecking)
        precondition(manager.updates == pendingUpdates, "Cancellation must retain pending updates")
        precondition(manager.lastCheckedDate == checkedDate, "Cancellation must not count as a completed check")
        precondition(manager.checkIssues.count == 1 && manager.checkIssues[0].contains(String(localized: "Update check was cancelled. Pull down to retry.")))
        precondition(!manager.checkIssues.contains { $0.contains(String.localized("linked repository is unavailable. Refresh or restore its source in Sources.")) })
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
        precondition(!manager.checkIssues.contains { $0.contains(String.localized("linked repository is unavailable. Refresh or restore its source in Sources.")) })
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
        let multiA = AltSource(sourceURL: URL(string: "https://example.com/a.json")!, name: "A", identifier: "source.a")
        let multiB = AltSource(sourceURL: URL(string: "https://example.com/b.json")!, name: "B", identifier: "source.b")
        let manualCurrent = LocalApp(uuid: "manual-current", version: "1.0", source: nil, date: Date(timeIntervalSince1970: 200))
        let priorHigher = LocalApp(uuid: "prior-higher", version: "9.0", source: nil, date: Date(timeIntervalSince1970: 100))
        let pendingHigher = LocalApp(uuid: "pending-higher", version: "3.0", source: nil, isSigned: false, date: Date(timeIntervalSince1970: 300))
        let inventory = [manualCurrent, priorHigher, pendingHigher]
        precondition(AppInventory.applications(inventory).count == 1)
        precondition(AppInventory.applications(inventory)[0].installed?.uuid == manualCurrent.uuid, "Latest signature wins, including deliberate downgrade; imports do not change installed version")
        var aVersion = "1.1", bVersion = "1.2"
        FixtureProtocol.response = { request in
            let isA = request.url == multiA.sourceURL
            let data = try! JSONSerialization.data(withJSONObject: ["identifier": isA ? "source.a" : "source.b", "name": isA ? "A" : "B", "apps": [app(version: isA ? aVersion : bVersion)]])
            return (data, 200)
        }
        await manager.checkForUpdates(sources: [multiA, multiB], localApps: inventory)
        precondition(manager.updates.count == 1 && manager.updates["manual-current"]?.remoteVersion == "1.2")
        precondition(manager.updates["manual-current"]?.sourceURL == multiB.sourceURL)
        UserDefaults.standard.set(["id:source.b"], forKey: "SignOs.disabledSources")
        manager.sourceAvailabilityChanged()
        precondition(manager.updates["manual-current"]?.sourceURL == multiA.sourceURL, "Disabling immediately falls back to the other enabled source")
        let beforeDisabledCheck = FixtureProtocol.requests.count
        await manager.checkForUpdates(sources: [multiA, multiB], localApps: inventory)
        precondition(FixtureProtocol.requests.count == beforeDisabledCheck + 1, "Disabled sources are not fetched by update checking")
        UserDefaults.standard.set(["id:source.a", "id:source.b"], forKey: "SignOs.disabledSources")
        manager.sourceAvailabilityChanged()
        precondition(manager.updates.isEmpty && inventory.count == 3)
        UserDefaults.standard.removeObject(forKey: "SignOs.disabledSources")
        aVersion = "1.2"
        await manager.checkForUpdates(sources: [multiA, multiB], localApps: [manualCurrent])
        precondition(manager.updates.isEmpty && manager.candidates[bundle]?.count == 2 && !manager.checkIssues.isEmpty, "Ambiguous equal versions ask once")
        manager.selectCandidate(manager.candidates[bundle]!.first { $0.sourceURL == multiB.sourceURL }!, for: bundle)
        await manager.checkForUpdates(sources: [multiA, multiB], localApps: [manualCurrent])
        precondition(manager.updates["manual-current"]?.sourceURL == multiB.sourceURL, "The explicit equal-version preference survives refresh")
        UserDefaults.standard.removeObject(forKey: "SignOs.preferredUpdateSources")
        aVersion = "0.9"; bVersion = "1.0"
        await manager.checkForUpdates(sources: [multiA, multiB], localApps: [manualCurrent])
        precondition(manager.updates.isEmpty, "Lower/equal versions do not count as updates")
        FixtureProtocol.response = nil
        checkpoint("cross-source newest version, grouping, manual imports, disable fallback, equal-version choice and downgrade prevention passed")
        Storage.shared.reset()
        try fixture([app(legacy: false), app(entry: "other", legacy: false)])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && !manager.checkIssues.isEmpty)
        precondition(Storage.shared.sourceMetadata(for: "museum") == nil, "Ambiguous variants must not be backfilled")
        try fixture([app()], id: "unrelated.source")
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates["museum"]?.remoteVersion == "1.1.3" && manager.checkIssues.isEmpty, "A different enabled source may update the same bundle")
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
        precondition(!manager.checkIssues.contains { $0.contains(String.localized("linked repository is unavailable. Refresh or restore its source in Sources.")) })
        try fixture([app(version: "1.1.2")])
        await manager.checkForUpdates(sources: [source], localApps: [local])
        precondition(manager.updates.isEmpty && manager.checkIssues.isEmpty, "Successful retry must clear failures")
        precondition(Storage.shared.sourceMetadata(for: "museum")?.sourceAppVersion == "1.1.2")
        await manager.checkForUpdates(sources: [], localApps: [local])
        precondition(manager.updates.isEmpty && manager.checkIssues.isEmpty, "No enabled source means no update candidates, not a missing ownership error")
        checkpoint("HTTP/JSON failures and retry passed")
        let beforePreflightCancellation = FixtureProtocol.requests.count
        let cancelledPreflight = await manager.checkForUpdates(sources: [source], localApps: [local], synchronizeSources: {
            throw CancellationError()
        })
        precondition(!cancelledPreflight && FixtureProtocol.requests.count == beforePreflightCancellation)
        precondition(manager.checkIssues.last?.contains(String(localized: "Update check was cancelled. Pull down to retry.")) == true)

        let remoteStore = CloudSourceStore(session: URLSession(configuration: configuration))
        var catalogRequests = 0
        var syncRequests = 0
        func catalog(status: String, failed: Bool = false) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "revision": 1, "settings": ["id": "yao", "identifier": officialID, "name": "Official", "description": "Fixture"],
                "entries": [["id": "entry", "revision": 1, "config": ["kind": "github", "paused": false],
                             "published": true, "history": [], "status": status,
                             "error": failed ? ["code": "upstream", "message": "Upstream unavailable"] as Any : NSNull()],
                            ["id": "paused", "revision": 1, "config": ["kind": "github", "paused": true],
                             "published": true, "history": [], "status": "queued"]]
            ])
        }
        FixtureProtocol.response = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            precondition(request.cachePolicy == .reloadIgnoringLocalCacheData, "Synchronization must poll fresh catalog data")
            if request.url!.path == "/api/entries/entry/sync" {
                precondition(request.httpMethod == "POST")
                syncRequests += 1
                return (Data("{}".utf8), 202)
            }
            precondition(request.url!.path == "/api/catalog")
            catalogRequests += 1
            return (catalog(status: catalogRequests == 2 ? "queued" : "succeeded"), 200)
        }
        let remoteIssues = try await remoteStore.synchronizeAndWait(address: "https://example.com", token: "fixture-token", expectedIdentifier: officialID)
        precondition(remoteIssues.isEmpty && syncRequests == 1 && catalogRequests == 3 && !remoteStore.isBusy)
        FixtureProtocol.response = { _ in (catalog(status: "failed", failed: true), 200) }
        let failures = try await remoteStore.synchronizeAndWait(address: "https://example.com", token: "fixture-token", expectedIdentifier: officialID)
        precondition(failures == ["新订阅: Upstream unavailable"])
        let requestsBeforeMismatch = FixtureProtocol.requests.count
        do {
            _ = try await remoteStore.synchronizeAndWait(address: "https://example.com", token: "fixture-token", expectedIdentifier: "another.source")
            preconditionFailure("Mismatched source must not synchronize")
        } catch {
            precondition(FixtureProtocol.requests.count == requestsBeforeMismatch + 1 && !remoteStore.isBusy)
        }
        FixtureProtocol.error = URLError(.cancelled)
        do {
            _ = try await remoteStore.synchronizeAndWait(address: "https://example.com", token: "fixture-token", expectedIdentifier: officialID)
            preconditionFailure("Remote cancellation must propagate")
        } catch {
            precondition((error as? URLError)?.code == .cancelled && !remoteStore.isBusy)
        }
        FixtureProtocol.error = nil
        FixtureProtocol.response = nil
        checkpoint("remote synchronization waits for parsing, reports failures, rejects mismatched sources and propagates cancellation")

        print("UpdateManagerRegression passed: migrated legacy record, durable local version, variants, holds/skips, cancellation, HTTP/JSON failures, removed source and retry")
    }
}
