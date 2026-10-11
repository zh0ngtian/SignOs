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
		// v2 migrated the source but left URL-only imported/signed records behind.
		// Only recognize the documented official move, never infer a source from an app ID.
		if storedIdentifier == nil,
			currentIdentifier == "tech.zh0ngtian.yao-app-source",
			normalizedURL(storedURL) == "https://yao-app-source.305301890.workers.dev/source.json",
			normalizedURL(currentURL) == "https://signos-source-aggregator.305301890.workers.dev/sources/yao.json" {
			return true
		}
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
