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
		print("SourceRepositoryIdentityRegression passed (9 cases)")
	}
}
