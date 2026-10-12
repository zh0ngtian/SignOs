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

	func schedule(for signedUUID: String, signed: [String] = [], imported: [String] = [],
				  manuallyDeletedImports: [String] = []) {
		var pending = plans
		var plan = pending[signedUUID] ?? Plan()
		plan.signed.formUnion(signed.filter { $0 != signedUUID })
		// Re-signing a retained archive must carry its original imported package forward.
		for oldUUID in plan.signed {
			if let oldPlan = pending[oldUUID] {
				plan.imported.formUnion(oldPlan.imported)
				plan.manuallyDeletedImports.formUnion(oldPlan.manuallyDeletedImports)
			}
		}
		plan.imported.formUnion(imported)
		plan.manuallyDeletedImports.formUnion(manuallyDeletedImports)
		pending[signedUUID] = plan
		plans = pending
	}

	/// Called only after observed server progress ends or paired installation succeeds.
	func installationEnded(for signedUUID: String, replaceOldVersions: Bool,
						   delete: (String, Bool) -> Void) {
		var pending = plans
		guard let plan = pending[signedUUID] else { return }
		if replaceOldVersions {
			plan.signed.forEach { delete($0, true) }
		}
		let imports = replaceOldVersions
			? plan.imported.union(plan.manuallyDeletedImports) : plan.manuallyDeletedImports
		imports.forEach { delete($0, false) }
		if replaceOldVersions {
			// Deleted older archives no longer need their own deferred cleanup plans.
			plan.signed.forEach { pending.removeValue(forKey: $0) }
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
