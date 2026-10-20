import Foundation

extension AppOperations {
    static func originalIdentifier(for app: any AppInfoPresentable) -> String? {
        app.originalIdentifier ?? app.identifier
    }

    static func signingOptions(for app: any AppInfoPresentable, base: Options? = nil,
                               updating baseline: (any AppInfoPresentable)? = nil) -> Options {
        var options = base ?? OptionsManager.shared.options
        let owner = baseline ?? app
        if let original = originalIdentifier(for: owner) {
            options.originalIdentifier = original
            options.appIdentifier = AppBundleIdentifierPreferences.shared.identifier(for: original)
        }
        if let baseline, baseline.identifier != app.identifier { options.appName = baseline.name }
        return options
    }
}
