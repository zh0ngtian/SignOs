import Foundation

@main struct SigningIdentityRegression {
    static func main() {
        let old = SigningIdentity(prefix: "PREFIX", teams: ["TEAM"], applicationIdentifier: "PREFIX.com.example.app", keychainGroups: ["PREFIX.com.example.app"], bundleIdentifier: "com.example.app")
        let renewed = SigningIdentity(prefix: "PREFIX", teams: ["TEAM"], applicationIdentifier: "PREFIX.com.example.app", keychainGroups: ["PREFIX.com.example.app"])
        precondition(renewed.canReplace(old, bundle: "com.example.app"))
        precondition(!renewed.canReplace(old, bundle: "com.example.other"))
        precondition(!SigningIdentity(prefix: "NEW", teams: ["TEAM"], applicationIdentifier: "NEW.*", keychainGroups: ["NEW.*"]).canReplace(old, bundle: "com.example.app"))
        precondition(!SigningIdentity(prefix: "PREFIX", teams: ["OTHER"], applicationIdentifier: "PREFIX.*", keychainGroups: ["PREFIX.*"]).canReplace(old, bundle: "com.example.app"))
        precondition(!SigningIdentity(prefix: "PREFIX", teams: ["TEAM"], applicationIdentifier: "PREFIX.*", keychainGroups: ["PREFIX.shared"]).canReplace(old, bundle: "com.example.app"))
        precondition(!SigningIdentity(prefix: "PREFIX", teams: ["TEAM"], applicationIdentifier: nil, keychainGroups: []).canReplace(old, bundle: "com.example.app"))
        let assigned = SigningIdentity(prefix: "PREFIX", teams: ["TEAM"], applicationIdentifier: "PREFIX.vendor.assigned", keychainGroups: ["PREFIX.vendor.assigned"])
        precondition(assigned.canReplace(assigned, bundle: "com.example.app"), "Do not replace the real Bundle ID with a signing App ID")
        precondition(!renewed.canReplace(assigned, bundle: "com.example.app"))
        var grouped = old; grouped.appGroups = ["group.example.shared"]
        precondition(!renewed.canReplace(grouped, bundle: "com.example.app"))
        var supported = renewed; supported.appGroups = ["group.example.shared", "group.example.additional"]
        precondition(supported.canReplace(grouped, bundle: "com.example.app"))
        print("SigningIdentityRegression passed: renewal, explicit/wildcard App IDs, team/prefix changes and keychain continuity")
    }
}
