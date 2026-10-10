import Foundation

/// A repository can move to another URL while keeping its published identifier.
enum SourceRepositoryIdentity {
	static func matches(
		storedURL: URL,
		storedIdentifier: String?,
		currentURL: URL,
		currentIdentifier: String?
	) -> Bool {
		if normalizedURL(storedURL) == normalizedURL(currentURL) { return true }
		guard
			let storedIdentifier, !storedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let currentIdentifier, !currentIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { return false }
		return storedIdentifier == currentIdentifier
	}

	private static func normalizedURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		let value = (components?.url ?? url).absoluteString
		return value.hasSuffix("/") ? String(value.dropLast()) : value
	}
}
