import Foundation

/// Source signing keeps the installation intent and the saved target identity together.
@MainActor
enum ManualSigningFlow {
    enum Purpose {
        case sign, sourceInstall
    }

    static func prepare(_ options: Options, for app: any AppInfoPresentable,
                        purpose: Purpose) throws -> Options {
        guard purpose == .sourceInstall else { return options }
        guard let original = AppOperations.originalIdentifier(for: app) else {
            throw failure("无法确定应用的原始 Bundle ID。")
        }
        let identifier = AppBundleIdentifierPreferences.shared.identifier(for: original)
        if let error = AppBundleIdentifierPreferences.validationError(for: identifier) {
            throw failure(error)
        }
        var prepared = options
        prepared.appIdentifier = identifier
        prepared.originalIdentifier = original
        return prepared
    }

    static func installationResult(for app: any AppInfoPresentable, options: Options,
                                   purpose: Purpose) throws -> Signed? {
        guard purpose == .sourceInstall || options.post_installAppAfterSigned else { return nil }
        guard !SourceAccessManager.shared.wasSuppressed(app.uuid), AppOperations.isAllowed(app) else { return nil }
        // Use this attempt's output, including a changed Bundle ID, never an older package.
        guard let input = app.uuid,
              let output = SourceAccessManager.shared.signedResults[input],
              let result = AppOperations.signedResult(for: app), result.uuid == output,
              result.identifier == (options.appIdentifier ?? app.identifier) else {
            throw failure("签名结果未找到，未开始安装。请保留本地包并重试。")
        }
        return AppOperations.isAllowed(result) ? result : nil
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SignOs.Signing", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
