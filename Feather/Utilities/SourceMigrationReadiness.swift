import Foundation

enum SourceMigrationReadiness {
    static let identifier = "tech.zh0ngtian.yao-app-source"
    static let requiredBundles: Set<String> = [
        "tech.zh0ngtian.MuseumMuse", "com.bilibili.inter", "com.signos.app", "vip.loock.codexmobile"
    ]

    private struct Source: Decodable {
        let identifier: String
        let apps: [App]
    }

    private struct App: Decodable {
        let bundleIdentifier: String
        let legacyDefault: Bool?
        let version: String?
        let sha256: String?
        let size: Int?
        let downloadURL: URL?
    }

    static func canMigrate(_ data: Data) throws -> Bool {
        let source = try JSONDecoder().decode(Source.self, from: data)
        guard source.identifier == identifier else { return false }
        let verified = source.apps.filter {
            $0.legacyDefault == true && $0.version?.isEmpty == false &&
            $0.sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
            ($0.size ?? 0) > 0 && $0.downloadURL?.scheme == "https"
        }
        return requiredBundles.isSubset(of: Set(verified.map(\.bundleIdentifier)))
    }
}
