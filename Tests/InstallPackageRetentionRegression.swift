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
		print("InstallPackageRetentionRegression passed: pending/failed retention, progress end, persisted retry, paired completion, file/metadata cleanup, replacement toggle, manual signing")
	}
}
