import Foundation

@main
struct CloudSourceLiveRegression {
    @MainActor
    static func main() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/signos-source-aggregator/credentials.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        let endpoint = try CloudSourceEndpoint.baseURL(config["url"]!)
        let previous = CloudSourceCredentials.read(for: endpoint)
        let store = CloudSourceStore()
        await store.connect(address: config["url"]!, token: config["token"]!)
        guard store.errorMessage == nil, let snapshot = store.snapshot else {
            fatalError(store.errorMessage ?? "Missing catalog")
        }
        precondition(snapshot.entries.count >= 2)
        precondition(snapshot.entries.contains { $0.current?.metadata.bundleIdentifier == "com.bilibili.inter" })
        let backup = try await store.exportBackup()
        let object = try JSONSerialization.jsonObject(with: backup) as! [String: Any]
        precondition(object["signature"] != nil)
        precondition(!String(decoding: backup, as: UTF8.self).contains(config["token"]!))
        precondition(CloudSourceCredentials.read(for: endpoint) == config["token"]!)
        store.disconnect()
        if let previous { try CloudSourceCredentials.save(previous, for: endpoint) }
        print("Cloud source client live API decoding, backup and Keychain checks passed (\(snapshot.entries.count) entries)")
    }
}
