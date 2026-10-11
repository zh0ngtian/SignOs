import Foundation

@main
struct SourceMigrationReadinessRegression {
    static func main() throws {
        func app(_ bundle: String, legacy: Bool = true, hash: String = String(repeating: "a", count: 64)) -> [String: Any] {
            ["bundleIdentifier": bundle, "legacyDefault": legacy, "version": "1.0", "sha256": hash,
             "size": 123, "downloadURL": "https://github.com/example/repo/releases/download/v1/App.ipa"]
        }
        func ready(_ apps: [[String: Any]], identifier: String = SourceMigrationReadiness.identifier) throws -> Bool {
            try SourceMigrationReadiness.canMigrate(JSONSerialization.data(withJSONObject: ["identifier": identifier, "apps": apps]))
        }
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        let complete = SourceMigrationReadiness.requiredBundles.sorted().map { app($0) }
        check(try ready(complete), "All latest signed packages should enable source cutover")
        check(try !ready(Array(complete.dropLast())), "Partial migration must retain the old source")
        check(try !ready(complete, identifier: "another.source"), "A different source must not trigger cutover")
        var unsigned = complete.filter { $0["bundleIdentifier"] as? String != "vip.loock.codexmobile" }
        unsigned.append(app("vip.loock.codexmobile", legacy: false))
        check(try !ready(unsigned), "Unsigned Codex must not substitute the existing signed variant")
        var unverified = complete
        unverified[0]["sha256"] = ""
        check(try !ready(unverified), "Unverified packages must not enable cutover")
        print("SourceMigrationReadinessRegression passed (5 cases)")
    }
}
