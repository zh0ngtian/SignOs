import Foundation

/// Shared fallbacks for settings and installers before preferences are saved.
enum InstallationDefaults {
	static let serverMethod = 1 // Semi Local: remote HTTPS manifest, local HTTP IPA.
	static let onlyLocalhost = true

	static func serverMethod(in defaults: UserDefaults = .standard) -> Int {
		defaults.object(forKey: "Feather.serverMethod") as? Int ?? serverMethod
	}

	static func onlyLocalhost(in defaults: UserDefaults = .standard) -> Bool {
		defaults.object(forKey: "Feather.ipFix") as? Bool ?? onlyLocalhost
	}
}
