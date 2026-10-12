import Foundation

enum SourceSubscriptionIdentity {
    static func key(bundleIdentifier: String, subscriptionID: String?) -> String {
        guard let subscriptionID, !subscriptionID.isEmpty else { return bundleIdentifier }
        return "signos-subscription:\(bundleIdentifier):\(subscriptionID)"
    }

    static func bundleIdentifier(from key: String) -> String {
        guard key.hasPrefix("signos-subscription:") else { return key }
        return String(key.dropFirst("signos-subscription:".count).split(separator: ":", maxSplits: 1)[0])
    }

    static func matchIndex(storedKey: String, candidates: [(bundle: String, subscriptionID: String?)], legacyPreferredIndex: Int? = nil) -> Int? {
        let exact = candidates.indices.filter { key(bundleIdentifier: candidates[$0].bundle, subscriptionID: candidates[$0].subscriptionID) == storedKey }
        if exact.count == 1 { return exact[0] }
        if let index = legacyPreferredIndex, candidates.indices.contains(index), candidates[index].bundle == storedKey { return index }
        // Legacy bundle-only metadata can migrate only when the variant is unambiguous.
        let legacy = candidates.indices.filter { candidates[$0].bundle == storedKey }
        return legacy.count == 1 ? legacy[0] : nil
    }
}
