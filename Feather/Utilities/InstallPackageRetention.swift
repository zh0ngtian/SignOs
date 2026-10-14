import Foundation

/// Persist cleanup plans so a manual retry after relaunch uses the same packages.
@MainActor
final class InstallPackageRetention {
	static let shared = InstallPackageRetention()
	private let defaults: UserDefaults
	private let key = "SignOs.pendingInstallCleanup"

	private struct Plan: Codable {
		var signed: Set<String> = []
		var imported: Set<String> = []
		var manuallyDeletedImports: Set<String> = []
		var protected: Set<String>?
		var installationRequested: Bool? = false
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	private var plans: [String: Plan] {
		get {
			guard let data = defaults.data(forKey: key) else { return [:] }
			return (try? JSONDecoder().decode([String: Plan].self, from: data)) ?? [:]
		}
		set {
			if let data = try? JSONEncoder().encode(newValue) {
				defaults.set(data, forKey: key)
			}
		}
	}

	/// Manual cleanup must preserve every package in pending/failed install plans.
	var protectedPackageUUIDs: Set<String> {
		plans.reduce(into: Set<String>()) { result, entry in
			result.insert(entry.key)
			result.formUnion(entry.value.signed)
			result.formUnion(entry.value.imported)
			result.formUnion(entry.value.manuallyDeletedImports)
			result.formUnion(entry.value.protected ?? [])
		}
	}

	func schedule(for signedUUID: String, signed: [String] = [], imported: [String] = [],
				  manuallyDeletedImports: [String] = [], protected: [String] = []) {
		var pending = plans
		var plan = pending[signedUUID] ?? Plan()
		plan.signed.formUnion(signed.filter { $0 != signedUUID })
		// Re-signing a retained archive must carry its original imported package forward.
		for oldUUID in plan.signed {
			if let oldPlan = pending[oldUUID] {
				plan.imported.formUnion(oldPlan.imported)
				plan.manuallyDeletedImports.formUnion(oldPlan.manuallyDeletedImports)
				plan.protected = (plan.protected ?? []).union(oldPlan.protected ?? [])
			}
		}
		plan.imported.formUnion(imported)
		plan.manuallyDeletedImports.formUnion(manuallyDeletedImports)
		plan.protected = (plan.protected ?? []).union(protected)
		pending[signedUUID] = plan
		plans = pending
	}

	/// A newer signature takes over unstarted signatures' protection, but never an outstanding install.
	func scheduleAfterSigning(for signedUUID: String, protected: [String]) {
		var pending = plans
		var plan = pending[signedUUID] ?? Plan()
		for uuid in protected where uuid != signedUUID {
			guard let previous = pending[uuid], previous.installationRequested == false else { continue }
			plan.signed.formUnion(previous.signed)
			plan.imported.formUnion(previous.imported)
			plan.manuallyDeletedImports.formUnion(previous.manuallyDeletedImports)
			plan.protected = (plan.protected ?? []).union(previous.protected ?? [])
			pending.removeValue(forKey: uuid)
		}
		plan.protected = (plan.protected ?? []).union(protected)
		pending[signedUUID] = plan
		plans = pending
	}

	func beginInstallation(for signedUUID: String, protected: [String]) {
		schedule(for: signedUUID, protected: protected)
		var pending = plans
		pending[signedUUID]?.installationRequested = true
		plans = pending
	}

	/// Called only after observed server progress ends or paired installation succeeds.
	func installationEnded(for signedUUID: String, replaceOldVersions: Bool,
						   delete: (String, Bool) -> Void) {
		var pending = plans
		guard let plan = pending[signedUUID] else { return }
		// Missing markers in legacy plans mean unknown/possibly active, never safe to supersede.
		let protectedElsewhere = pending.filter { $0.key != signedUUID && $0.value.installationRequested != false }
			.reduce(into: Set<String>()) { result, entry in
				result.insert(entry.key)
				result.formUnion(entry.value.signed)
				result.formUnion(entry.value.imported)
				result.formUnion(entry.value.manuallyDeletedImports)
				result.formUnion(entry.value.protected ?? [])
			}
		if replaceOldVersions {
			plan.signed.filter { !protectedElsewhere.contains($0) }.forEach { delete($0, true) }
		}
		let imports = replaceOldVersions
			? plan.imported.union(plan.manuallyDeletedImports) : plan.manuallyDeletedImports
		imports.filter { !protectedElsewhere.contains($0) }.forEach { delete($0, false) }
		if replaceOldVersions {
			// Deleted older archives no longer need their own deferred cleanup plans.
			plan.signed.filter { pending[$0]?.installationRequested == false }.forEach { pending.removeValue(forKey: $0) }
		}
		pending.removeValue(forKey: signedUUID)
		plans = pending
	}
}

/// An absent/zero progress value before installation starts must not trigger cleanup.
struct InstallProgressTracker {
	private(set) var hasStarted = false
	private var hasEnded = false

	mutating func observe(_ progress: Double?) -> Bool {
		guard !hasEnded else { return false }
		if let progress, progress > 0 {
			hasStarted = true
			return false
		}
		guard hasStarted, progress == nil || progress == 0 else { return false }
		hasEnded = true
		return true
	}
}
