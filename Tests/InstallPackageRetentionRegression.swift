// Run the production cleanup policy and storage deletion against isolated Core Data/files.
import Foundation
import CoreData

class StoredPackage: NSManagedObject {
	@NSManaged var uuid: String?
	@NSManaged var name: String?
	@NSManaged var version: String?
	@NSManaged var identifier: String?
	var icon: String? { nil }
	var source: URL? { nil }
	var date: Date? { nil }
}

final class CertificatePair {}
@objc(Signed)
final class Signed: StoredPackage {
	static func fetchRequest() -> NSFetchRequest<Signed> { NSFetchRequest(entityName: "Signed") }
	var certificate: CertificatePair? { nil }
	override func validateForDelete() throws {
		if uuid == "database-failure", UserDefaults.standard.bool(forKey: "SignOsRegression.failDelete") {
			throw CocoaError(.validationMissingMandatoryProperty)
		}
		try super.validateForDelete()
	}
}
@objc(Imported)
final class Imported: StoredPackage {
	static func fetchRequest() -> NSFetchRequest<Imported> { NSFetchRequest(entityName: "Imported") }
}

extension FileManager {
	static let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	func signed(_ uuid: String) -> URL { Self.packageRoot.appendingPathComponent("Signed/\(uuid)") }
	func unsigned(_ uuid: String) -> URL { Self.packageRoot.appendingPathComponent("Imported/\(uuid)") }
	func getPath(in url: URL, for suffix: String) -> URL? { url.appendingPathComponent("Test.\(suffix)") }
}

final class Storage {
	@MainActor static let shared = Storage()
	let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
	var deletedMetadata: Set<String> = []
	init() {
		let model = NSManagedObjectModel()
		model.entities = [("Signed", Signed.self), ("Imported", Imported.self)].map { name, type in
			let entity = NSEntityDescription()
			entity.name = name
			entity.managedObjectClassName = NSStringFromClass(type)
			entity.properties = ["uuid", "name", "version", "identifier"].map { name in
				let attribute = NSAttributeDescription()
				attribute.name = name
				attribute.attributeType = .stringAttributeType
				attribute.isOptional = true
				return attribute
			}
			return entity
		}
		let metadata = NSEntityDescription()
		metadata.name = "AppSourceMetadata"
		metadata.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
		let appUUID = NSAttributeDescription()
		appUUID.name = "appUUID"
		appUUID.attributeType = .stringAttributeType
		metadata.properties = [appUUID]
		model.entities.append(metadata)
		let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
		try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
		context.persistentStoreCoordinator = coordinator
	}
	func saveContext() { try! context.save() }
	func deleteSourceMetadata(for uuid: String?) { if let uuid { deletedMetadata.insert(uuid) } }
}

@MainActor enum AppOperations {
    static var disabledSources = Set<String>()
    static func isSourceManaged(_ app: AppInfoPresentable) -> Bool { app.uuid.map { disabledSources.contains($0) } ?? false }
    static func isAllowed(_ app: AppInfoPresentable) -> Bool { !isSourceManaged(app) }
    static func packages() -> [any AppInfoPresentable] {
        let context = Storage.shared.context
        return (try! context.fetch(Signed.fetchRequest())).map { $0 as any AppInfoPresentable }
            + (try! context.fetch(Imported.fetchRequest())).map { $0 as any AppInfoPresentable }
    }
}

@MainActor final class SourceAccessManager {
    static let shared = SourceAccessManager()
    var activeUUIDs = Set<String>()
    var activeIdentifiers = Set<String>()
    func isInUse(_ uuid: String?) -> Bool { uuid.map(activeUUIDs.contains) ?? false }
    func hasActiveApplication(_ identifier: String) -> Bool { activeIdentifiers.contains(identifier) }
}
@MainActor final class AutoSignManager {
    struct Job { let appUUID: String; let appIdentifier: String? }
    static let shared = AutoSignManager()
    var queue: [Job] = []
    var currentJob: Job?
}
@MainActor final class DownloadManager {
    struct Provenance { let sourceAppIdentifier: String }
    struct Download { let targetAppUUID: String?; var sourceProvenance: Provenance? }
    static let shared = DownloadManager()
    var downloads: [Download] = []
}
@MainActor final class UpdateManager {
    static let shared = UpdateManager()
    var localUUIDs = Set<String>()
    func sourceAvailabilityChanged(localApps: [any AppInfoPresentable]) { localUUIDs = Set(localApps.compactMap(\.uuid)) }
}
@MainActor final class AutoUpdateManager {
    static let shared = AutoUpdateManager()
    var badgeRefreshes = 0
    func updateBadgeFromState() { badgeRefreshes += 1 }
}

@main
struct InstallPackageRetentionRegression {
	@MainActor
	static func main() throws {
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "SignOs.pendingInstallCleanup")
		defaults.set(true, forKey: "SignOs.autoDeleteOldVersions")
		defer {
			defaults.removeObject(forKey: "SignOs.pendingInstallCleanup")
			defaults.removeObject(forKey: "SignOs.autoDeleteOldVersions")
			try? FileManager.default.removeItem(at: FileManager.packageRoot)
		}
		let storage = Storage.shared
		func package(_ uuid: String, signed: Bool) throws -> StoredPackage {
			let app = NSEntityDescription.insertNewObject(forEntityName: signed ? "Signed" : "Imported", into: storage.context) as! StoredPackage
			app.uuid = uuid
			app.identifier = "test.app"
			let url = signed ? FileManager.default.signed(uuid) : FileManager.default.unsigned(uuid)
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			try Data(uuid.utf8).write(to: url.appendingPathComponent("package"))
			storage.saveContext()
			return app
		}
		func exists(_ uuid: String, signed: Bool) -> Bool {
			FileManager.default.fileExists(atPath: (signed ? FileManager.default.signed(uuid) : FileManager.default.unsigned(uuid)).path)
		}
		let old = try package("old", signed: true)
		let imported = try package("source", signed: false)
		let current = try package("current", signed: true) as! Signed
		_ = try package("unrelated", signed: true)
		let retention = InstallPackageRetention.shared
		retention.schedule(for: "current", signed: ["old", "current"], imported: ["source"])
		retention.schedule(for: "current", manuallyDeletedImports: ["source"])
		precondition(retention.protectedPackageUUIDs == ["current", "old", "source"], "Manual cleanup must protect the complete pending install plan")
		var tracker = InstallProgressTracker()
		for progress in [nil, 0, nil, 0] as [Double?] {
			precondition(!tracker.observe(progress), "A prompt/absent progress must not end installation")
		}
		precondition(exists("old", signed: true) && exists("source", signed: false), "Signing and failed/pending installation must retain both packages")
		precondition(!tracker.observe(0.65) && !tracker.observe(1), "Active progress, including 100%, must retain packages")
		precondition(exists("source", signed: false))
		// A retry after restart must recover the persisted cleanup plan.
		let reloaded = InstallPackageRetention(defaults: defaults)
		precondition(tracker.observe(nil), "Disappearing progress after it starts must end installation")
		var victims: Set<String> = []
		reloaded.installationEnded(for: "current", replaceOldVersions: true) { uuid, _ in victims.insert(uuid) }
		precondition(reloaded.protectedPackageUUIDs.isEmpty, "Installation completion releases manual cleanup protection")
		precondition(victims == ["old", "source"], "Never delete the current or unrelated signed package")
		// Re-register the same plan to verify actual production Core Data and file deletion.
		retention.schedule(for: "current", signed: ["old", "current"], imported: ["source"])
		storage.finishInstallCleanup(for: current)
		precondition(!exists("old", signed: true) && !exists("source", signed: false))
		precondition(exists("current", signed: true) && exists("unrelated", signed: true))
		precondition(old.isDeleted || old.managedObjectContext == nil)
		precondition(imported.isDeleted || imported.managedObjectContext == nil)
		precondition(storage.deletedMetadata == ["old", "source"])
		precondition(!tracker.observe(0) && !tracker.observe(nil), "Cleanup must only trigger once")
		storage.finishInstallCleanup(for: current)
		precondition(storage.deletedMetadata.count == 2)
		var zeroTracker = InstallProgressTracker()
		precondition(!zeroTracker.observe(0.9) && zeroTracker.observe(0))
		_ = try package("retained-old", signed: true)
		_ = try package("retained-source", signed: false)
		retention.schedule(for: "current", signed: ["retained-old"], imported: ["retained-source"])
		defaults.set(false, forKey: "SignOs.autoDeleteOldVersions")
		storage.finishInstallCleanup(for: current)
		precondition(exists("retained-old", signed: true) && exists("retained-source", signed: false), "Disabling replacement must preserve both kinds of packages")
		_ = try package("manual-source", signed: false)
		retention.schedule(for: "current", manuallyDeletedImports: ["manual-source"])
		precondition(exists("manual-source", signed: false), "Manual signing deletion is deferred too")
		storage.finishInstallCleanup(for: current)
		precondition(!exists("manual-source", signed: false))
		precondition(exists("retained-source", signed: false) && exists("current", signed: true))
		_ = try package("retry-source", signed: false)
		_ = try package("retry-signed", signed: true)
		let resigned = try package("resigned", signed: true) as! Signed
		retention.schedule(for: "retry-signed", imported: ["retry-source"])
		retention.schedule(for: "resigned", signed: ["retry-signed"])
		precondition(exists("retry-source", signed: false), "Re-signing must still retain the original download")
		defaults.set(true, forKey: "SignOs.autoDeleteOldVersions")
		storage.finishInstallCleanup(for: resigned)
		precondition(!exists("retry-signed", signed: true) && !exists("retry-source", signed: false))
		precondition(exists("resigned", signed: true))
        _ = try package("disabled-signed", signed: true)
        _ = try package("disabled-import", signed: false)
        AppOperations.disabledSources = ["disabled-signed", "disabled-import"]
        retention.schedule(for: "resigned", signed: ["disabled-signed"], imported: ["disabled-import"])
        storage.finishInstallCleanup(for: resigned)
        precondition(exists("disabled-signed", signed: true) && exists("disabled-import", signed: false), "An update from another source must preserve disabled-source archives")
		let failed = try package("failed-delete", signed: true) as! Signed
		let parent = FileManager.default.signed("failed-delete").deletingLastPathComponent()
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
		do {
			try storage.deleteAppReportingErrors(for: failed)
			preconditionFailure("A failed file deletion must be thrown to the cleanup UI")
		} catch {
			precondition(exists("failed-delete", signed: true) && !failed.isDeleted)
			precondition(!storage.deletedMetadata.contains("failed-delete"), "Failed deletion preserves metadata for retry")
		}
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
		try storage.deleteAppReportingErrors(for: failed)
		precondition(!exists("failed-delete", signed: true))
		let databaseFailure = try package("database-failure", signed: true) as! Signed
		defaults.set(true, forKey: "SignOsRegression.failDelete")
		defer { defaults.removeObject(forKey: "SignOsRegression.failDelete") }
		do {
			try storage.deleteAppReportingErrors(for: databaseFailure)
			preconditionFailure("A real Core Data validation failure must be reported")
		} catch {
			precondition(!databaseFailure.isDeleted && storage.context.deletedObjects.isEmpty,
				"The failed transaction must leave the shared context clean and the record available for retry")
			try storage.context.save()
			precondition(try! storage.context.fetch(Signed.fetchRequest()).contains { $0.uuid == "database-failure" })
		}
		defaults.set(false, forKey: "SignOsRegression.failDelete")
		try storage.deleteAppReportingErrors(for: databaseFailure)
		let direct = try package("direct-install", signed: true) as! Signed
		direct.identifier = "direct.app"
		let directOld = try package("direct-old", signed: true)
		directOld.identifier = "direct.app"
		storage.saveContext()
		storage.protectPackagesAwaitingInstallation(for: direct)
		let restart = InstallPackageRetention(defaults: defaults)
		precondition(restart.protectedPackageUUIDs.isSuperset(of: ["direct-install", "direct-old"]),
			"A direct install and its older siblings remain protected after restart")
		var unexpectedlyDeleted: [String] = []
		restart.installationEnded(for: "direct-install", replaceOldVersions: true) { uuid, _ in unexpectedlyDeleted.append(uuid) }
		precondition(unexpectedlyDeleted.isEmpty && !restart.protectedPackageUUIDs.contains("direct-old"),
			"Protection-only plans unlock after installation without changing automatic deletion preferences")
		try manualDeletion()
        try pendingInstallationDeletion()
		print("InstallPackageRetentionRegression passed: pending/failed retention, installation cleanup, manual deletion, explicit abandonment/cancellation, busy recheck, stale consent, shared/legacy plan isolation and failure retry")
	}

    @MainActor
    private static func manualDeletion() throws {
        let storage = Storage.shared
        let bundle = "manual.delete.app"
        let preferences: [String: Any] = [
            "SignOs.deletedSubscriptions": ["unrelated-subscription"],
            "SignOs.disabledSources": ["disabled-source"],
            "SignOs.heldApps": [bundle],
            "SignOs.preferredUpdateSources": [bundle: "source-a"],
        ]
        preferences.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
        defer { preferences.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        func package(_ uuid: String, signed: Bool, identifier: String = "manual.delete.app") throws -> StoredPackage {
            let app = NSEntityDescription.insertNewObject(forEntityName: signed ? "Signed" : "Imported", into: storage.context) as! StoredPackage
            app.uuid = uuid; app.name = "测试应用"; app.version = "1.0"; app.identifier = identifier
            let directory = storage.getUuidDirectory(for: app as! any AppInfoPresentable)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(uuid.utf8).write(to: directory.appendingPathComponent("package"))
            let metadata = NSEntityDescription.insertNewObject(forEntityName: "AppSourceMetadata", into: storage.context)
            metadata.setValue(uuid, forKey: "appUUID")
            try storage.context.save()
            return app
        }
        func uuids() -> Set<String> { Set(AppOperations.packages().compactMap(\.uuid)) }
        func metadataExists(_ uuid: String) -> Bool {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AppSourceMetadata")
            request.predicate = NSPredicate(format: "appUUID == %@", uuid)
            return try! storage.context.count(for: request) > 0
        }
        _ = try package("delete-source-a", signed: true)
        _ = try package("delete-source-b", signed: true)
        _ = try package("delete-import", signed: false)
        _ = try package("keep-clone", signed: true, identifier: bundle + ".clone")
        _ = try package("keep-other", signed: false, identifier: "other.app")
        let application = AppInventory.applications(AppOperations.packages()).first { $0.id == bundle }!
        let request = AppPackageDeletion.Request(application: application)
        precondition(request.count == 3)
        // Changes while confirmation is open must be checked before deleting any sibling.
        AutoSignManager.shared.queue = [.init(appUUID: "delete-import", appIdentifier: bundle)]
        precondition(AppPackageDeletion.remove(request.target).removed == 0 && uuids().contains("delete-source-a"))
        AutoSignManager.shared.queue = []
        AutoSignManager.shared.currentJob = .init(appUUID: "delete-import", appIdentifier: bundle + ".clone")
        precondition(!AppPackageDeletion.remove(request.target).failures.isEmpty, "A clone job still protects its original input")
        AutoSignManager.shared.currentJob = nil
        SourceAccessManager.shared.activeIdentifiers = [bundle]
        precondition(!AppPackageDeletion.remove(.package("delete-source-a")).failures.isEmpty, "Sibling installs protect every package")
        SourceAccessManager.shared.activeIdentifiers = []
        SourceAccessManager.shared.activeUUIDs = ["delete-import"]
        precondition(!AppPackageDeletion.remove(request.target).failures.isEmpty)
        SourceAccessManager.shared.activeUUIDs = []
        DownloadManager.shared.downloads = [.init(targetAppUUID: "delete-source-a")]
        precondition(!AppPackageDeletion.remove(request.target).failures.isEmpty)
        DownloadManager.shared.downloads = [.init(targetAppUUID: nil, sourceProvenance: .init(
            sourceAppIdentifier: SourceSubscriptionIdentity.key(bundleIdentifier: bundle, subscriptionID: "source-a")))]
        precondition(!AppPackageDeletion.remove(request.target).failures.isEmpty, "First-time source downloads protect this application too")
        DownloadManager.shared.downloads = []
        InstallPackageRetention.shared.schedule(for: "delete-source-a", imported: ["delete-import"])
        precondition(AppPackageDeletion.remove(request.target).requiresConfirmation != nil, "Pending installation requires explicit abandonment consent")
        InstallPackageRetention.shared.installationEnded(for: "delete-source-a", replaceOldVersions: false) { _, _ in }
        AppOperations.disabledSources.insert("delete-source-b")
        let single = AppPackageDeletion.remove(.package("delete-source-b"))
        precondition(single.removed == 1 && single.failures.isEmpty, "Explicit deletion supports disabled source archives")
        precondition(!uuids().contains("delete-source-b") && uuids().contains("delete-source-a") && uuids().contains("delete-import"))
        precondition(!metadataExists("delete-source-b"))
        _ = try package("late-history", signed: true)
        let all = AppPackageDeletion.remove(request.target)
        precondition(all.removed == 3 && all.failures.isEmpty, "Resolve every local version again after confirmation")
        precondition(uuids().isSuperset(of: ["keep-clone", "keep-other"]))
        precondition(!uuids().contains("delete-source-a") && !uuids().contains("late-history") && !uuids().contains("delete-import"))
        precondition(!metadataExists("delete-source-a") && !metadataExists("late-history") && !metadataExists("delete-import"))
        precondition(!FileManager.default.fileExists(atPath: FileManager.default.signed("late-history").path))
        precondition(UpdateManager.shared.localUUIDs == uuids() && AutoUpdateManager.shared.badgeRefreshes >= 2,
                     "Deletion refreshes local update baselines and the badge")
        precondition(AppPackageDeletion.remove(request.target).removed == 0, "Confirming an already removed application is harmless")
        for (key, value) in preferences {
            precondition((UserDefaults.standard.object(forKey: key) as AnyObject).isEqual(value), "Local deletion must preserve subscription and update preferences")
        }

        _ = try package("partial-failure", signed: true)
        _ = try package("partial-success", signed: false)
        let parent = FileManager.default.signed("partial-failure").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let partial = AppPackageDeletion.remove(.application(bundle))
        precondition(partial.removed == 1 && partial.failures.count == 1)
        precondition(uuids().contains("partial-failure") && !uuids().contains("partial-success"))
        precondition(metadataExists("partial-failure") && !metadataExists("partial-success"), "File failures preserve their database and metadata records")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        precondition(AppPackageDeletion.remove(.application(bundle)).removed == 1, "Failed deletions remain retryable")

        AppBundleIdentifierPreferences.shared.save("custom.delete.target", for: "custom.delete.original")
        _ = try package("custom-input", signed: false, identifier: "custom.delete.original")
        _ = try package("custom-output", signed: true, identifier: "custom.delete.target")
        _ = try package("custom-clone", signed: true, identifier: "custom.delete.target.clone")
        let custom = AppInventory.applications(AppOperations.packages()).first { $0.id == "custom.delete.target" }!
        precondition(custom.packages.count == 2)
        SourceAccessManager.shared.activeUUIDs = ["custom-input"]
        precondition(!AppPackageDeletion.remove(.application(custom.id)).failures.isEmpty, "Merged inputs remain protected while used")
        SourceAccessManager.shared.activeUUIDs = []
        let customDeleted = AppPackageDeletion.remove(.application(custom.id))
        precondition(customDeleted.removed == 2 && uuids().contains("custom-clone"), "Deleting the target card includes its original input and preserves clones")
        precondition(AppBundleIdentifierPreferences.shared.identifier(for: "custom.delete.original") == custom.id)
    }

    @MainActor
    private static func pendingInstallationDeletion() throws {
        let storage = Storage.shared
        let retention = InstallPackageRetention.shared
        func package(_ uuid: String, signed: Bool, identifier: String = "pending.delete.app") throws -> StoredPackage {
            let app = NSEntityDescription.insertNewObject(forEntityName: signed ? "Signed" : "Imported", into: storage.context) as! StoredPackage
            app.uuid = uuid; app.name = "待安装测试"; app.version = "1.0"; app.identifier = identifier
            let directory = storage.getUuidDirectory(for: app as! any AppInfoPresentable)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(uuid.utf8).write(to: directory.appendingPathComponent("package"))
            try storage.context.save()
            return app
        }
        func exists(_ uuid: String) -> Bool { AppOperations.packages().contains { $0.uuid == uuid } }
        _ = try package("pending-output", signed: true)
        _ = try package("pending-input", signed: false)
        _ = try package("other-output", signed: true, identifier: "other.pending.app")
        _ = try package("other-input", signed: false, identifier: "other.pending.app")
        retention.scheduleAfterSigning(for: "pending-output", protected: ["pending-output", "pending-input"])
        retention.schedule(for: "other-output", imported: ["other-input"], protected: ["pending-input"])
        let target = AppPackageDeletion.Target.application("pending.delete.app")
        let prompt = AppPackageDeletion.remove(target)
        let consent = prompt.requiresConfirmation!
        precondition(prompt.removed == 0 && prompt.failures.isEmpty)
        precondition(exists("pending-output") && exists("pending-input"), "Showing or cancelling the second confirmation must leave every package intact")
        precondition(InstallPackageRetention(defaults: .standard).protectedPackageUUIDs.isSuperset(of: ["pending-output", "pending-input", "other-output", "other-input"]), "Automatic cleanup protection survives cancellation and restart")

        // Work may begin after the dialog was shown; consent must not bypass any runtime guard.
        SourceAccessManager.shared.activeIdentifiers = ["pending.delete.app"]
        let busy = AppPackageDeletion.remove(target, abandoning: consent)
        precondition(busy.removed == 0 && !busy.failures.isEmpty && busy.requiresConfirmation == nil)
        SourceAccessManager.shared.activeIdentifiers = []
        AutoSignManager.shared.queue = [.init(appUUID: "pending-input", appIdentifier: "pending.delete.app")]
        precondition(!AppPackageDeletion.remove(target, abandoning: consent).failures.isEmpty)
        AutoSignManager.shared.queue = []
        DownloadManager.shared.downloads = [.init(targetAppUUID: "pending-output")]
        precondition(!AppPackageDeletion.remove(target, abandoning: consent).failures.isEmpty)
        DownloadManager.shared.downloads = []
        precondition(exists("pending-output") && retention.protectedPackageUUIDs.contains("pending-input"))

        retention.beginInstallation(for: "pending-output", protected: ["pending-output", "pending-input"])
        let changed = AppPackageDeletion.remove(target, abandoning: consent)
        precondition(changed.removed == 0 && changed.requiresConfirmation != nil && changed.requiresConfirmation != consent,
                     "A changed installation plan invalidates previous consent")
        let deleted = AppPackageDeletion.remove(target, abandoning: changed.requiresConfirmation)
        precondition(deleted.removed == 2 && deleted.failures.isEmpty && deleted.requiresConfirmation == nil)
        precondition(!exists("pending-output") && !exists("pending-input"))
        let afterRestart = InstallPackageRetention(defaults: .standard)
        precondition(!afterRestart.protectedPackageUUIDs.contains("pending-output") && !afterRestart.protectedPackageUUIDs.contains("pending-input"))
        precondition(afterRestart.protectedPackageUUIDs.isSuperset(of: ["other-output", "other-input"]), "Shared input references are pruned without cancelling another application's retry plan")

        // A single imported/history package may be removed while keeping its signed output retryable.
        _ = try package("single-output", signed: true, identifier: "single.pending.app")
        _ = try package("single-history", signed: true, identifier: "single.pending.app")
        _ = try package("single-input", signed: false, identifier: "single.pending.app")
        retention.schedule(for: "single-output", signed: ["single-history"], imported: ["single-input"], manuallyDeletedImports: ["single-input"], protected: ["single-input"])
        let single = AppPackageDeletion.Target.package("single-input")
        let singleConsent = AppPackageDeletion.remove(single).requiresConfirmation!
        precondition(AppPackageDeletion.remove(single, abandoning: singleConsent).removed == 1)
        precondition(retention.protectedPackageUUIDs.isSuperset(of: ["single-output", "single-history"]) && !retention.protectedPackageUUIDs.contains("single-input"))
        var laterCleanup = Set<String>()
        retention.installationEnded(for: "single-output", replaceOldVersions: true) { uuid, _ in laterCleanup.insert(uuid) }
        precondition(laterCleanup == ["single-history"], "Later cleanup must not refer to an explicitly deleted input")

        _ = try package("pending-failure", signed: true, identifier: "failure.pending.app")
        retention.schedule(for: "pending-failure")
        let failedTarget = AppPackageDeletion.Target.package("pending-failure")
        let failedConsent = AppPackageDeletion.remove(failedTarget).requiresConfirmation!
        let parent = FileManager.default.signed("pending-failure").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let failure = AppPackageDeletion.remove(failedTarget, abandoning: failedConsent)
        precondition(failure.removed == 0 && failure.failures.count == 1)
        precondition(exists("pending-failure") && retention.protectedPackageUUIDs.contains("pending-failure"), "Deletion failure retains the package and its retry protection")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        precondition(AppPackageDeletion.remove(failedTarget, abandoning: failedConsent).removed == 1)
        precondition(!retention.protectedPackageUUIDs.contains("pending-failure"))

        // Legacy plans lack an installationRequested marker; only explicit consent releases them.
        _ = try package("legacy-output", signed: true, identifier: "legacy.pending.app")
        _ = try package("legacy-input", signed: false, identifier: "legacy.pending.app")
        let key = "SignOs.pendingInstallCleanup"
        var legacy = try JSONSerialization.jsonObject(with: UserDefaults.standard.data(forKey: key)!) as! [String: Any]
        legacy["legacy-output"] = ["signed": [], "imported": ["legacy-input"], "manuallyDeletedImports": []]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
        let legacyTarget = AppPackageDeletion.Target.application("legacy.pending.app")
        let legacyConsent = AppPackageDeletion.remove(legacyTarget).requiresConfirmation!
        precondition(AppPackageDeletion.remove(legacyTarget, abandoning: legacyConsent).removed == 2)
        precondition(!InstallPackageRetention(defaults: .standard).protectedPackageUUIDs.contains("legacy-output"))
        precondition(retention.protectedPackageUUIDs.isSuperset(of: ["other-output", "other-input"]))
    }
}
