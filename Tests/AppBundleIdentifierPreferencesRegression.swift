import Foundation

@main struct AppBundleIdentifierPreferencesRegression {
    @MainActor static func main() {
        let suite = "SignOs.bundle-id-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = "com.example.app"
        let custom = "com.example.personal"
        let preferences = AppBundleIdentifierPreferences(defaults: defaults)
        precondition(preferences.identifier(for: original) == original)
        preferences.save(custom, for: original)
        let restarted = AppBundleIdentifierPreferences(defaults: defaults)
        precondition(restarted.identifier(for: original) == custom, "A fresh instance must restore the local preference")
        precondition(restarted.identifier(for: "com.example.other") == "com.example.other", "Other apps keep their original identity")
        let clone = original + ".clone123"
        restarted.save("com.example.personal.clone", for: clone)
        precondition(restarted.identifier(for: original) == custom, "A clone must not overwrite its parent's preference")
        restarted.save(original, for: original)
        let restored = AppBundleIdentifierPreferences(defaults: defaults)
        precondition(restored.identifier(for: original) == original)
        precondition(restored.configuredIdentifier(for: original) == original, "An explicit reset must override global replacement rules")
        precondition(restored.identifier(for: clone) == "com.example.personal.clone")
        for value in ["", "com..example", ".example", "com.example.", "com.ex ample", "com.example_*", "com.应用"] {
            precondition(AppBundleIdentifierPreferences.validationError(for: value) != nil, "Reject malformed input: \(value)")
        }
        for value in [original, "com.Example-1.app", clone] {
            precondition(AppBundleIdentifierPreferences.validationError(for: value) == nil)
        }
        print("AppBundleIdentifierPreferencesRegression passed: original defaults, local reload, independent apps/clones, explicit reset and input validation")
    }
}
