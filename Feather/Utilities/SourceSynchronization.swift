import Foundation

@MainActor
enum SourceSynchronization {
    static func synchronizeManagedSources(_ sources: [AltSource]) async throws -> [String] {
        var visited: Set<URL> = []
        var issues: [String] = []
        for source in sources {
            try Task.checkCancellation()
            guard let endpoint = CloudSourceEndpoint.managementURL(for: source.sourceURL),
                  let token = CloudSourceCredentials.read(for: endpoint),
                  visited.insert(endpoint).inserted else { continue }
            do {
                let failures = try await CloudSourceStore().synchronizeAndWait(
                    address: endpoint.absoluteString, token: token, expectedIdentifier: source.identifier
                )
                issues += failures.map { "\(source.name ?? .localized("Source")): \($0)" }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                issues.append("\(source.name ?? .localized("Source")): \(error.localizedDescription)")
            }
        }
        return issues
    }
}
