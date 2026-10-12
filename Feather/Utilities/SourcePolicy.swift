import Foundation

enum SourcePolicy {
    static func keys(url: URL?, identifier: String?) -> [String] {
        var result = [String]()
        if url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://yao-app-source.305301890.workers.dev/source.json" { result.append("id:tech.zh0ngtian.yao-app-source") }
        if let identifier, !identifier.isEmpty { result.append("id:" + identifier) }
        if let url { result.append("url:" + url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        return result
    }

    static func isEnabled(url: URL?, identifier: String?) -> Bool {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "SignOs.disabledSources") ?? [])
        return keys(url: url, identifier: identifier).allSatisfy { !disabled.contains($0) }
    }

    static func subscriptionKey(url: URL?, identifier: String?, appIdentifier: String) -> String {
        (keys(url: url, identifier: identifier).first ?? "unknown") + "|" + appIdentifier
    }

    static func isSubscriptionDeleted(url: URL?, identifier: String?, appIdentifier: String) -> Bool {
        let deleted = Set(UserDefaults.standard.stringArray(forKey: "SignOs.deletedSubscriptions") ?? [])
        return keys(url: url, identifier: identifier).contains { deleted.contains($0 + "|" + appIdentifier) }
    }
}
