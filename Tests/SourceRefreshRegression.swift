// Run the production source refresh, synchronization, HTTP client and policy in Simulator.
import Foundation
import CoreData
import AltSourceKit

// The isolated command-line app has no Keychain entitlement; never use real credentials.
@MainActor enum CloudSourceCredentials {
    private static var tokens: [URL: String] = [:]
    static func read(for endpoint: URL) -> String? { tokens[endpoint] }
    static func save(_ token: String, for endpoint: URL) throws { tokens[endpoint] = token }
    static func remove(for endpoint: URL) { tokens[endpoint] = nil }
}

@objc(AltSource)
final class AltSource: NSManagedObject {
    @NSManaged var name: String?
    @NSManaged var identifier: String?
    @NSManaged var sourceURL: URL?
    @NSManaged var iconURL: URL?
}

final class Storage {
    static let shared = Storage()
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    init() {
        let entity = NSEntityDescription()
        entity.name = "AltSource"
        entity.managedObjectClassName = NSStringFromClass(AltSource.self)
        entity.properties = ["name", "identifier", "sourceURL", "iconURL"].map { name in
            let property = NSAttributeDescription()
            property.name = name
            property.attributeType = name.hasSuffix("URL") ? .URIAttributeType : .stringAttributeType
            property.isOptional = true
            return property
        }
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context.persistentStoreCoordinator = coordinator
    }
    func getSources() -> [AltSource] { try! context.fetch(NSFetchRequest(entityName: "AltSource")) }
    func saveContext() { try! context.save() }
    func add(_ host: String, path: String = "/source.json") -> AltSource {
        let source = AltSource(context: context)
        source.name = host
        source.identifier = host
        source.sourceURL = URL(string: "https://\(host)\(path)")!
        saveContext()
        return source
    }
}

@MainActor final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class SourceFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Fixture.respond(self) } }
    override func stopLoading() {}
    func reply(_ object: [String: Any], status: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
        client!.urlProtocolDidFinishLoading(self)
    }
}

@MainActor enum Fixture {
    static var events: [String] = []
    static var entered = Gate()
    static var holdCatalog = false
    static var held: SourceFixtureProtocol?
    static var failSync = false
    static var failFeed = false
    static var feedName = "New catalog"
    static func reset() {
        events = []; entered = Gate(); holdCatalog = false; held = nil
        failSync = false; failFeed = false
    }
    static func respond(_ connection: SourceFixtureProtocol) {
        let request = connection.request, url = connection.request.url!
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        events.append("\(request.httpMethod!) \(url.host!)\(url.path)")
        if url.path.hasPrefix("/api/") {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            precondition(url.host == "managed.test", "Disabled and credential-free sources must not synchronize")
        }
        if url.path == "/api/catalog" {
            if holdCatalog { holdCatalog = false; held = connection; entered.open(); return }
            connection.reply([
                "revision": 1,
                "settings": ["id": "managed", "identifier": "managed.test", "name": "Managed", "description": "Fixture"],
                "entries": [["id": "entry", "revision": 1, "config": ["kind": "github", "paused": false],
                             "published": true, "history": [], "status": failSync ? "failed" : "succeeded",
                             "error": failSync ? ["code": "upstream", "message": "Upstream unavailable"] as Any : NSNull()]]
            ])
        } else if url.path.hasSuffix("/sync") {
            connection.reply([:], status: 202)
        } else {
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            connection.reply(["identifier": url.host!, "name": feedName,
                              "apps": [["name": "Fixture", "bundleIdentifier": "com.example.fixture", "version": "2.0",
                                        "iconURL": "https://example.com/icon.png",
                                        "downloadURL": "https://example.com/fixture.ipa"]]],
                             status: failFeed && url.host == "managed.test" ? 503 : 200)
        }
    }
    static func release() { let connection = held!; held = nil; respond(connection) }
    static var syncCount: Int { events.filter { $0.hasPrefix("POST ") }.count }
}

@main struct SourceRefreshRegression {
    @MainActor static func main() async throws {
        URLProtocol.registerClass(SourceFixtureProtocol.self)
        let storage = Storage.shared, model = SourcesViewModel()
        let managed = storage.add("managed.test")
        let plain = storage.add("static.test", path: "/feed.json")
        let publicSource = storage.add("public.test")
        let disabled = storage.add("disabled.test")
        for host in ["managed.test", "disabled.test"] {
            try CloudSourceCredentials.save("fixture", for: URL(string: "https://\(host)")!)
        }
        UserDefaults.standard.set(["id:disabled.test"], forKey: "SignOs.disabledSources")

        // A page disappearing cancels its waiter; the shared refresh must still finish once.
        Fixture.holdCatalog = true
        let caller = Task { await model.synchronizeAndRefreshSources() }
        await Fixture.entered.wait()
        precondition(model.isSynchronizingSources)
        caller.cancel()
        let duplicate = Task { await model.synchronizeAndRefreshSources() }
        await Task.yield()
        Fixture.release()
        await caller.value
        await duplicate.value
        precondition(Fixture.syncCount == 1, "Repeated pulls must join the active synchronization")
        let sync = Fixture.events.firstIndex { $0.hasPrefix("POST ") }!
        let feed = Fixture.events.firstIndex(of: "GET managed.test/source.json")!
        precondition(sync < feed, "Remote synchronization must precede catalog loading")
        precondition([managed, plain, publicSource, disabled].allSatisfy { model.sources[$0]?.name == "New catalog" }, "\(model.sourceRefreshIssues)")
        precondition(model.sourceRefreshIssues.isEmpty && !model.isSynchronizingSources)

        // Remote and feed failures stay visible; an unsuccessful feed cannot erase good data.
        Fixture.reset(); Fixture.failSync = true; Fixture.failFeed = true; Fixture.feedName = "Updated static"
        await model.synchronizeAndRefreshSources()
        precondition(model.sourceRefreshIssues.count == 2)
        precondition(model.sourceRefreshIssues.contains { $0.contains("Upstream unavailable") })
        precondition(model.sourceRefreshIssues.contains { $0.hasPrefix("managed.test:") })
        precondition(model.sources[managed]?.name == "New catalog")
        precondition(model.sources[plain]?.name == "Updated static")

        // Deleting a source while remote work runs must not fetch or republish it.
        Fixture.reset(); Fixture.holdCatalog = true; Fixture.feedName = "Retry catalog"
        let retry = Task { await model.synchronizeAndRefreshSources() }
        await Fixture.entered.wait()
        storage.context.delete(publicSource)
        Fixture.release()
        await retry.value
        precondition(!Fixture.events.contains("GET public.test/source.json"))
        precondition(model.sources[managed]?.name == "Retry catalog")
        precondition(model.sourceRefreshIssues.isEmpty && !model.isSynchronizingSources)
        precondition(Fixture.syncCount == 1, "Retry must create a new synchronization task")
        print("SourceRefreshRegression passed: sync-before-feed, credentials/disabled/static policy, uncached HTTP, coalescing, cancelled waiter, visible failures, retained data, deletion and retry")
    }
}
