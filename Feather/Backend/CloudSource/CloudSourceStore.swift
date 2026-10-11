import Foundation
import Observation

@Observable @MainActor
final class CloudSourceStore {
    private(set) var snapshot: CloudSourceSnapshot?
    private(set) var isBusy = false
    var errorMessage: String?
    private(set) var endpoint: URL?
    @ObservationIgnored private var token = ""

    var sourceURL: URL? {
        guard let endpoint, let id = snapshot?.settings.id else { return nil }
        return endpoint.appendingPathComponent("sources/\(id).json")
    }

    func connect(address: String, token: String) async {
        await perform {
            let endpoint = try CloudSourceEndpoint.baseURL(address)
            self.endpoint = endpoint
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
        snapshot = try JSONDecoder().decode(CloudSourceSnapshot.self, from: data)
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let endpoint else { throw URLError(.badURL) }
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("SignOs-App/1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
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
