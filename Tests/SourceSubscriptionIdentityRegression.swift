import Foundation

@main struct SourceSubscriptionIdentityRegression {
    static func main() {
        let variants: [(bundle: String, subscriptionID: String?)] = [("com.example.app", "standard"), ("com.example.app", "se")]
        let standard = SourceSubscriptionIdentity.key(bundleIdentifier: "com.example.app", subscriptionID: "standard")
        let se = SourceSubscriptionIdentity.key(bundleIdentifier: "com.example.app", subscriptionID: "se")
        precondition(standard != se)
        precondition(SourceSubscriptionIdentity.matchIndex(storedKey: se, candidates: variants) == 1)
        precondition(SourceSubscriptionIdentity.matchIndex(storedKey: "com.example.app", candidates: variants) == nil)
        precondition(SourceSubscriptionIdentity.matchIndex(storedKey: "com.example.app", candidates: [variants[0]]) == 0)
        precondition(SourceSubscriptionIdentity.matchIndex(storedKey: "com.other.app", candidates: variants) == nil)
        precondition(SourceSubscriptionIdentity.key(bundleIdentifier: "com.example.legacy", subscriptionID: nil) == "com.example.legacy")
        precondition(SourceSubscriptionIdentity.matchIndex(storedKey: "com.example.app", candidates: variants, legacyPreferredIndex: 0) == 0)
        print("Source subscription identity regressions passed")
    }
}
