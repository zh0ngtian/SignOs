import Foundation

final class SubscriptionFixtureProtocol: URLProtocol {
    static var revision = 0
    static var entries: [[String: Any]] = []
    static var writes: [[String: Any]] = []
    static var failPattern: String?
    static var loseResponsePattern: String?
    static var failRefresh = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        func respond(_ object: [String: Any], status: Int = 200) {
            client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
            client!.urlProtocolDidFinishLoading(self)
        }
        if request.url!.path == "/api/catalog" {
            if Self.failRefresh { respond(["error": ["code": "UNAVAILABLE", "message": "刷新失败"]], status: 503); return }
            respond(["revision": Self.revision, "settings": ["id": "test", "identifier": "test.source", "name": "Test", "description": ""], "entries": Self.entries])
            return
        }
        let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? request.httpBodyStream!.readData()) as! [String: Any]
        if request.url!.path == "/api/discover" {
            respond(["candidates": [
                ["id": 1, "name": "App-v1.2.3-unsigned.ipa", "tag": "v1.2.3", "size": 123, "url": "https://fixture.example/unsigned.ipa"],
                ["id": 2, "name": "App-v1.2.3-signed.ipa", "tag": "v1.2.3", "size": 124, "url": "https://fixture.example/signed.ipa"]
            ]])
            return
        }
        precondition(body["revision"] as! Int == Self.revision, "Each write must use the last returned revision")
        var config = body["config"] as! [String: Any]
        Self.writes.append(config)
        if config["assetPattern"] as? String == Self.failPattern {
            respond(["error": ["code": "ENTRY_LIMIT", "message": "模拟添加失败"]], status: 422)
            return
        }
        config["repository"] = "owner/repo"
        Self.revision += 1
        let entry: [String: Any] = ["id": UUID().uuidString, "revision": 1, "config": config,
            "published": false, "history": [], "status": "queued"]
        Self.entries.append(entry)
        if config["assetPattern"] as? String == Self.loseResponsePattern {
            client!.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        respond(["revision": Self.revision, "entry": entry])
    }
}

private extension InputStream {
    func readData() -> Data {
        open(); defer { close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

@main
struct CloudSourceSubscriptionRegression {
    @MainActor
    static func main() async throws {
        let names = ["App-v1.2.3-unsigned.ipa", "App-v1.2.3-signed.ipa"]
        let patterns = names.map { CloudSourceAssetRule.suggestedPattern(for: $0, candidateNames: names) }
        precondition(patterns == ["App-*-unsigned.ipa", "App-*-signed.ipa"])
        for (index, pattern) in patterns.enumerated() {
            precondition(CloudSourceAssetRule.validationMessage(pattern: pattern, selectedName: names[index], candidateNames: names) == nil)
        }
        let variants = ["App-1.0.ipa", "App-2.0.ipa"]
        precondition(CloudSourceAssetRule.suggestedPattern(for: variants[0], candidateNames: variants) == variants[0])
        precondition(CloudSourceAssetRule.validationMessage(pattern: "App-*.ipa", selectedName: names[0], candidateNames: names) != nil)
        precondition(CloudSourceAssetRule.validationMessage(pattern: patterns[1], selectedName: names[0], candidateNames: names) != nil)
        precondition(CloudSourceAssetRule.validationMessage(pattern: " ", selectedName: names[0], candidateNames: names) != nil)
        precondition(CloudSourceAssetRule.validationMessage(pattern: "../*.ipa", selectedName: names[0], candidateNames: names) != nil)
        precondition(CloudSourceAssetRule.matches(pattern: "APP-?-unsigned.ipa", name: "app-x-unsigned.ipa"))
        precondition(CloudSourceAssetRule.matches(pattern: "App[SE]+(1).ipa", name: "App[SE]+(1).ipa"))
        precondition(!CloudSourceAssetRule.matches(pattern: "App[SE]+(1).ipa", name: "AppS1.ipa"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionFixtureProtocol.self]
        let store = CloudSourceStore(session: URLSession(configuration: configuration))
        let endpoint = "https://subscription-\(UUID().uuidString.lowercased()).example"
        await store.connect(address: endpoint, token: "test-token")
        defer { store.disconnect() }
        precondition(store.errorMessage == nil)
        var base = CloudSourceConfiguration()
        base.repository = "https://github.com/owner/repo/"
        let candidates = try await store.discover(config: base)
        precondition(candidates.count == 2 && candidates[0].id != candidates[1].id)
        let configs = patterns.map { pattern in
            var config = base
            config.assetPattern = pattern
            return config
        }
        let saved = await store.save(configurations: configs)
        precondition(saved == 2 && store.errorMessage == nil)
        precondition(store.snapshot?.entries.count == 2)
        precondition(Set(store.snapshot!.entries.map(\.id)).count == 2)
        precondition(store.snapshot!.entries.map(\.config.assetPattern) == patterns)

        var third = base; third.assetPattern = "App-SE.ipa"
        var fourth = base; fourth.assetPattern = "App-Pro.ipa"
        SubscriptionFixtureProtocol.failPattern = fourth.assetPattern
        let partial = await store.save(configurations: [third, fourth])
        precondition(partial == 1 && store.snapshot?.entries.count == 3)
        precondition(store.errorMessage?.contains("已添加 1 个订阅，剩余 1 个未添加") == true)
        SubscriptionFixtureProtocol.failPattern = nil
        let retried = await store.save(configurations: [fourth])
        precondition(retried == 1 && store.errorMessage == nil)
        precondition(store.snapshot?.entries.filter { $0.config.assetPattern == third.assetPattern }.count == 1)

        var lost = base; lost.assetPattern = "App-Lost.ipa"
        var remaining = base; remaining.assetPattern = "App-Remaining.ipa"
        SubscriptionFixtureProtocol.loseResponsePattern = lost.assetPattern
        let reconciled = await store.save(configurations: [lost, remaining])
        precondition(reconciled == 1 && store.snapshot?.entries.count == 5)
        SubscriptionFixtureProtocol.loseResponsePattern = nil
        let remainingCount = await store.save(configurations: [remaining])
        precondition(remainingCount == 1)
        precondition(store.snapshot?.entries.filter { $0.config.assetPattern == lost.assetPattern }.count == 1)

        SubscriptionFixtureProtocol.failRefresh = true
        var final = base; final.assetPattern = "Final.ipa"
        let finalCount = await store.save(configurations: [final])
        precondition(finalCount == 1 && store.errorMessage == "刷新失败", "Successful writes must not be retried if catalog refresh fails")
        SubscriptionFixtureProtocol.failRefresh = false
        await store.refresh()
        precondition(store.snapshot?.entries.count == 7)
        print("CloudSourceSubscriptionRegression passed: distinct rules/IDs, sequential revisions, partial retry, lost response and refresh failure")
    }
}
