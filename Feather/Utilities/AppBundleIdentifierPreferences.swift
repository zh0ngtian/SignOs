import Foundation
import Observation

/// Local preferences are keyed by the original identity, never by a source or version.
@MainActor @Observable
final class AppBundleIdentifierPreferences {
    static let shared = AppBundleIdentifierPreferences()
    @ObservationIgnored private let defaults: UserDefaults
    private let key = "SignOs.appBundleIdentifiers"
    private var identifiers: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        identifiers = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func configuredIdentifier(for original: String) -> String? {
        identifiers[original]
    }

    func identifier(for original: String) -> String {
        configuredIdentifier(for: original) ?? original
    }

    func save(_ identifier: String, for original: String) {
        // Keep an explicit original value so restoring also overrides global replacement rules.
        identifiers[original] = identifier
        defaults.set(identifiers, forKey: key)
    }

    static func validationError(for identifier: String) -> String? {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifier.isEmpty, parts.allSatisfy({ !$0.isEmpty }),
              identifier.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 46
              }) else {
            return "请输入有效的 Bundle ID：使用英文字母、数字、连字符和点，且每段不能为空，例如 com.example.app。"
        }
        return nil
    }
}
