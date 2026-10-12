import Foundation

struct SigningIdentity: Codable {
    let prefix: String
    let teams: Set<String>
    let applicationIdentifier: String?
    let keychainGroups: [String]
    var appGroups: [String] = []
    var bundleIdentifier: String? = nil

    func permits(_ bundle: String) -> Bool {
        guard let applicationIdentifier else { return false }
        let expected = prefix + "." + bundle
        if applicationIdentifier.hasSuffix("*") { return expected.hasPrefix(String(applicationIdentifier.dropLast())) }
        return applicationIdentifier == expected
    }

    func canReplace(_ previous: SigningIdentity, bundle: String?) -> Bool {
        guard prefix == previous.prefix, teams == previous.teams else { return false }
        guard let bundle else { return true }
        if let recorded = previous.bundleIdentifier, recorded != bundle { return false }
        guard let current = applicationIdentifier, let old = previous.applicationIdentifier else { return false }
        // Explicit signing App IDs may legitimately differ from CFBundleIdentifier.
        guard current == old else { return false }
        func resolved(_ groups: [String]) -> Set<String> {
            Set(groups.map { $0.replacingOccurrences(of: "*", with: bundle) })
        }
        return resolved(keychainGroups).isSuperset(of: resolved(previous.keychainGroups)) && Set(appGroups).isSuperset(of: Set(previous.appGroups))
    }
}
