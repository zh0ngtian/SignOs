import Foundation

final class ManagementFixtureProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var failure: URLError?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        if let failure = Self.failure {
            client!.urlProtocol(self, didFailWithError: failure)
            return
        }
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Self.body)
        client!.urlProtocolDidFinishLoading(self)
    }
}

@main
struct CloudSourceManagementRegression {
    static func main() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManagementFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let source = URL(string: "https://fixture.example/sources/test.json")!
        let endpoint = URL(string: "https://fixture.example")!
        ManagementFixtureProtocol.body = Data(#"{"service":"signos-source-aggregator","version":1,"sourceId":"test"}"#.utf8)
        let managed = await CloudSourceEndpoint.verifiedManagementURL(for: source, session: session)
        precondition(managed == endpoint, "Compatible management service must expose its settings entry")
        precondition(ManagementFixtureProtocol.requests.last?.url?.absoluteString == "https://fixture.example/health")
        precondition(ManagementFixtureProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == nil,
            "Detecting management support must not require or send a Token")

        for path in ["/source.json", "/appstore", "/sources/test.json"] {
            ManagementFixtureProtocol.status = 404
            let unsupported = await CloudSourceEndpoint.verifiedManagementURL(for: URL(string: "https://fixture.example" + path), session: session)
            precondition(unsupported == nil, "A static feed at a matching path must not expose management")
        }
        ManagementFixtureProtocol.status = 200
        for body in [#"{"service":"other-source-service"}"#, #"{"name":"Static source","apps":[]}"#, "not json"] {
            ManagementFixtureProtocol.body = Data(body.utf8)
            let unsupported = await CloudSourceEndpoint.verifiedManagementURL(for: source, session: session)
            precondition(unsupported == nil, "Unrelated or invalid health responses must not expose management")
        }
        ManagementFixtureProtocol.failure = URLError(.timedOut)
        let unavailable = await CloudSourceEndpoint.verifiedManagementURL(for: source, session: session)
        precondition(unavailable == nil)
        ManagementFixtureProtocol.failure = nil
        let requestCount = ManagementFixtureProtocol.requests.count
        for address in ["http://fixture.example/source.json", "https://fixture.example/repo.json"] {
            let unsupported = await CloudSourceEndpoint.verifiedManagementURL(for: URL(string: address), session: session)
            precondition(unsupported == nil)
        }
        precondition(ManagementFixtureProtocol.requests.count == requestCount,
            "Non-candidate feed addresses must not trigger management probes")
        print("CloudSourceManagementRegression passed: compatible service, static matching paths, unrelated/malformed health, timeout, no Token and no non-candidate requests")
    }
}
