import Foundation
import Observation

@Observable @MainActor
final class CloudSourceStore {
    private(set) var snapshot: CloudSourceSnapshot?
    private(set) var isBusy = false
    var errorMessage: String?
    private(set) var endpoint: URL?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var expectedIdentifier: String?

    init(session: URLSession = .shared) { self.session = session }

    var sourceURL: URL? {
        guard let endpoint, let id = snapshot?.settings.id else { return nil }
        return endpoint.appendingPathComponent("sources/\(id).json")
    }

    func connect(address: String, token: String, expectedIdentifier: String? = nil) async {
        await perform {
            let endpoint = try CloudSourceEndpoint.baseURL(address)
            self.endpoint = endpoint
            self.expectedIdentifier = expectedIdentifier
            self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try await self.load()
            try CloudSourceCredentials.save(self.token, for: endpoint)
        }
    }

    func disconnect() {
        if let endpoint { CloudSourceCredentials.remove(for: endpoint) }
        snapshot = nil
        token = ""
        endpoint = nil
        expectedIdentifier = nil
    }

    func refresh() async { await perform { try await self.load() } }

    func discover(config: CloudSourceConfiguration) async throws -> [CloudSourceCandidate] {
        struct Result: Decodable { let candidates: [CloudSourceCandidate] }
        let data = try await request("POST", "/api/discover", body: ["config": try object(config)])
        return try JSONDecoder().decode(Result.self, from: data).candidates
    }

    func save(config: CloudSourceConfiguration, entryID: String?) async -> Bool {
        var succeeded = false
        await perform {
            let path = entryID.map { "/api/entries/\($0)" } ?? "/api/entries"
            _ = try await self.request(entryID == nil ? "POST" : "PATCH", path, body: ["revision": self.snapshot?.revision ?? 0, "config": try self.object(config)])
            try await self.load()
            succeeded = true
        }
        return succeeded
    }

    /// Each IPA is a separate subscription. Return the successfully created prefix
    /// so a retry only submits the remaining selections, even if refreshing fails.
    func save(configurations: [CloudSourceConfiguration]) async -> Int {
        var savedCount = 0
        await perform {
            struct Result: Decodable {
                struct Entry: Decodable { let id: String }
                let revision: Int
                let entry: Entry
            }
            var revision = self.snapshot?.revision ?? 0
            var knownIDs = Set(self.snapshot?.entries.map(\.id) ?? [])
            var attemptedCount = 0
            do {
                for config in configurations {
                    try Task.checkCancellation()
                    attemptedCount += 1
                    let data = try await self.request("POST", "/api/entries", body: ["revision": revision, "config": try self.object(config)])
                    savedCount += 1
                    let result = try JSONDecoder().decode(Result.self, from: data)
                    revision = result.revision
                    knownIDs.insert(result.entry.id)
                }
            } catch {
                // A timed-out POST may have succeeded remotely. Reconcile that
                // attempt against new IDs before allowing the remaining retry.
                if (try? await self.load()) != nil, savedCount < attemptedCount,
                   self.snapshot?.entries.contains(where: { !knownIDs.contains($0.id) && $0.config.matchesSubscription(configurations[savedCount]) }) == true {
                    savedCount += 1
                }
                throw error
            }
            try await self.load()
        }
        if savedCount > 0, savedCount < configurations.count, let errorMessage {
            self.errorMessage = "已添加 \(savedCount) 个订阅，剩余 \(configurations.count - savedCount) 个未添加。\(errorMessage)"
        }
        return savedCount
    }

    func confirm(_ entry: CloudSourceEntry) async {
        await perform {
            _ = try await self.request("POST", "/api/entries/\(entry.id)/confirm", body: ["revision": self.snapshot?.revision ?? 0])
            try await self.load()
        }
    }

    func synchronize(_ entry: CloudSourceEntry? = nil) async {
        await perform {
            _ = try await self.request("POST", entry.map { "/api/entries/\($0.id)/sync" } ?? "/api/sync", body: [:])
            try await self.load()
        }
    }

    /// Manual update checks wait for remote parsing before downloading the public feed.
    func synchronizeAndWait(address: String, token: String, expectedIdentifier: String?) async throws -> [String] {
        guard !isBusy else { throw URLError(.resourceUnavailable) }
        isBusy = true
        defer { isBusy = false }
        endpoint = try CloudSourceEndpoint.baseURL(address)
        self.token = token
        self.expectedIdentifier = expectedIdentifier
        try await load()
        // Per-entry synchronization clears GitHub release caches; the bulk endpoint only schedules jobs.
        for entry in snapshot?.entries ?? [] where !entry.config.paused {
            try Task.checkCancellation()
            _ = try await request("POST", "/api/entries/\(entry.id)/sync", body: [:])
        }
        try await load()
        let deadline = Date().addingTimeInterval(60)
        while snapshot?.entries.contains(where: { !$0.config.paused && $0.isWorking }) == true {
            guard Date() < deadline else {
                throw NSError(domain: "CloudSource", code: 3, userInfo: [NSLocalizedDescriptionKey: "远端同步尚未完成，请稍后点击“检查”重试。"])
            }
            try await Task.sleep(for: .seconds(2))
            try await load()
        }
        try Task.checkCancellation()
        return snapshot?.entries.filter { !$0.config.paused && $0.status == "failed" }.map {
            "\($0.title): \($0.error?.message ?? $0.statusText)"
        } ?? []
    }

    func delete(_ entry: CloudSourceEntry) async {
        await perform {
            _ = try await self.request("DELETE", "/api/entries/\(entry.id)", body: ["revision": self.snapshot?.revision ?? 0])
            try await self.load()
        }
    }

    func updateSettings(name: String, description: String) async {
        await perform {
            _ = try await self.request("PATCH", "/api/settings", body: ["revision": self.snapshot?.revision ?? 0, "name": name, "description": description])
            try await self.load()
        }
    }

    func exportBackup() async throws -> Data { try await request("GET", "/api/export") }

    func restoreBackup(_ data: Data) async {
        await perform {
            let backup = try JSONSerialization.jsonObject(with: data)
            _ = try await self.request("POST", "/api/restore", body: ["revision": self.snapshot?.revision ?? 0, "backup": backup])
            try await self.load()
        }
    }

    func rotateToken() async -> String? {
        let newToken = UUID().uuidString + UUID().uuidString
        var succeeded = false
        await perform {
            _ = try await self.request("POST", "/api/token", body: ["token": newToken])
            self.token = newToken
            if let endpoint = self.endpoint { try CloudSourceCredentials.save(newToken, for: endpoint) }
            succeeded = true
        }
        return succeeded ? newToken : nil
    }

    private func load() async throws {
        let data = try await request("GET", "/api/catalog")
        let loaded = try JSONDecoder().decode(CloudSourceSnapshot.self, from: data)
        guard expectedIdentifier == nil || loaded.settings.identifier == expectedIdentifier else {
            snapshot = nil
            throw NSError(domain: "CloudSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "管理服务返回的软件源与当前订阅不一致。"])
        }
        snapshot = loaded
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let endpoint else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("SignOs-App/1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: CloudSourceFailure }
            let reason = try? JSONDecoder().decode(Failure.self, from: data)
            throw NSError(domain: "CloudSource", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: reason?.error.message ?? "软件源请求失败（HTTP \(http.statusCode)）"])
        }
        return data
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            errorMessage = error.localizedDescription
            // Refresh after a conflict to let the next edit use the current revision.
            if (error as NSError).code == 409 { try? await load() }
        }
    }
}
