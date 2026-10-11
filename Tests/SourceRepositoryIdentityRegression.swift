import Foundation

@main
struct SourceRepositoryIdentityRegression {
	static func main() {
		let oldURL = URL(string: "https://old.example/source.json")!
		let newURL = URL(string: "https://home.example:15006/source.json")!
		let identifier = "tech.example.app-source"
		func matches(_ storedID: String?, _ currentID: String?, _ currentURL: URL = newURL) -> Bool {
			SourceRepositoryIdentity.matches(
				storedURL: oldURL, storedIdentifier: storedID,
				currentURL: currentURL, currentIdentifier: currentID
			)
		}
		precondition(matches(identifier, identifier), "A moved repository must still provide updates")
		precondition(!matches(identifier, "another.source"), "Unrelated repositories must not provide updates")
		precondition(!matches(nil, identifier))
		precondition(!matches(identifier, nil))
		precondition(!matches("", ""))
		precondition(!matches("  ", "  "))
		precondition(matches(nil, nil, oldURL), "Legacy URL-only records must keep working")
		precondition(matches(nil, nil, URL(string: "HTTPS://OLD.EXAMPLE/source.json/#news")!))
		precondition(!matches(nil, nil, URL(string: "https://old.example/another.json")!))
		let officialID = "tech.zh0ngtian.yao-app-source"
        let legacyURL = URL(string: "https://yao-app-source.305301890.workers.dev/source.json")!
        let canonicalURL = URL(string: "https://signos-source-aggregator.305301890.workers.dev/sources/yao.json")!
        func official(_ storedURL: URL = legacyURL, _ storedID: String? = nil,
                      _ currentURL: URL = canonicalURL, _ currentID: String? = officialID) -> Bool {
            SourceRepositoryIdentity.matches(storedURL: storedURL, storedIdentifier: storedID,
                                             currentURL: currentURL, currentIdentifier: currentID)
        }
        precondition(official(), "Already-migrated URL-only records must find the official source")
        precondition(!official(legacyURL, "another.source"))
        precondition(!official(legacyURL, nil, canonicalURL, "another.source"))
        precondition(!official(legacyURL, nil, canonicalURL, nil))
        precondition(!official(oldURL))
        precondition(!official(URL(string: "http://yao-app-source.305301890.workers.dev/source.json")!))
        precondition(!official(legacyURL, nil, URL(string: "https://signos-source-aggregator.305301890.workers.dev/sources/other.json")!))
        precondition(!official(URL(string: legacyURL.absoluteString + "?other=1")!))
        print("SourceRepositoryIdentityRegression passed (17 cases)")
	}
}
