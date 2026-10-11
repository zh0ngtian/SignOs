import Foundation

extension Storage {
    /// Preserve the source identity and switch only once all latest packages are published.
    @MainActor
    func migrateOfficialCloudSource() async {
        let key = "SignOs.cloudSourceMigration.v2"
        guard !UserDefaults.standard.bool(forKey: key),
              getSources().contains(where: { $0.identifier == SourceMigrationReadiness.identifier }),
              let endpoint = try? CloudSourceEndpoint.baseURL(CloudSourceEndpoint.defaultURL) else { return }
        let sourceURL = endpoint.appendingPathComponent("sources/yao.json")
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("SignOs-App/1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                  try SourceMigrationReadiness.canMigrate(data),
                  !UserDefaults.standard.bool(forKey: key) else { return }
            let sources = getSources().filter { $0.identifier == SourceMigrationReadiness.identifier }
            guard !sources.isEmpty else { return }
            let previous = sources.map { ($0, $0.sourceURL, $0.iconURL) }
            for source in sources {
                source.sourceURL = sourceURL
                source.iconURL = endpoint.appendingPathComponent("icon.png")
            }
            do {
                if context.hasChanges { try context.save() }
                UserDefaults.standard.set(true, forKey: key)
            } catch {
                for (source, url, icon) in previous { source.sourceURL = url; source.iconURL = icon }
            }
        } catch { /* Keep the existing source and retry on a later launch. */ }
    }
}
