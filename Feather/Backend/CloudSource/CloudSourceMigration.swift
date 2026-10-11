import Foundation

extension Storage {
    /// Keep the official source identity while moving its cached URL once.
    @MainActor
    func migrateOfficialCloudSource() {
        let key = "SignOs.cloudSourceMigration.v1"
        guard !UserDefaults.standard.bool(forKey: key),
              let endpoint = try? CloudSourceEndpoint.baseURL(CloudSourceEndpoint.defaultURL) else { return }
        let sourceURL = endpoint.appendingPathComponent("sources/yao.json")
        for source in getSources() where source.identifier == "tech.zh0ngtian.yao-app-source" {
            source.sourceURL = sourceURL
            source.iconURL = endpoint.appendingPathComponent("icon.png")
        }
        do {
            if context.hasChanges { try context.save() }
            UserDefaults.standard.set(true, forKey: key)
        } catch { /* Retry on the next launch if persistence failed. */ }
    }
}
