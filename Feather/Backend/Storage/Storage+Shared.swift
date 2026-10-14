//
//  Storage+Shared.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData

// MARK: - Class extension: Apps (Shared)
extension Storage {
	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
			? FileManager.default.signed(uuid)
			: FileManager.default.unsigned(uuid)
	}
	
	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}
	
	func deleteApp(for app: AppInfoPresentable) {
		do {
			try _deleteAppFilesAndRecord(for: app)
			saveContext()
        } catch {
            NSLog("SignOs package cleanup failed: %@", error.localizedDescription)
        }
	}
	
	/// Report file/database failures to manual cleanup instead of claiming success.
	func deleteAppReportingErrors(for app: AppInfoPresentable) throws {
		// Persist pending edits first; failed deletions must never leak into viewContext.
		try context.save()
		guard let object = app as? NSManagedObject, let coordinator = context.persistentStoreCoordinator else {
			throw NSError(domain: "SignOs.StorageCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问应用数据库。"])
		}
		let transaction = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		transaction.persistentStoreCoordinator = coordinator
		defer { transaction.reset() }
		let victim = try transaction.existingObject(with: object.objectID)
		if coordinator.managedObjectModel.entitiesByName["AppSourceMetadata"] != nil, let uuid = app.uuid {
			let request = NSFetchRequest<NSManagedObject>(entityName: "AppSourceMetadata")
			request.predicate = NSPredicate(format: "appUUID == %@", uuid)
			try transaction.fetch(request).forEach(transaction.delete)
		}
		transaction.delete(victim)
		transaction.processPendingChanges()
		let changes: [AnyHashable: Any] = [
			NSDeletedObjectsKey: transaction.deletedObjects.map(\.objectID),
			NSUpdatedObjectsKey: transaction.updatedObjects.map(\.objectID)
		]
		if let url = getUuidDirectory(for: app), FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}
		try transaction.save()
		NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
	}

	private func _deleteAppFilesAndRecord(for app: AppInfoPresentable) throws {
		if let url = getUuidDirectory(for: app), FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}
		deleteSourceMetadata(for: app.uuid)
		if let object = app as? NSManagedObject { context.delete(object) }
	}

	@MainActor
	func protectPackagesAwaitingInstallation(for app: AppInfoPresentable) {
		guard app.isSigned, let uuid = app.uuid else { return }
		let related = AppOperations.packages().filter { app.identifier != nil && $0.identifier == app.identifier }.compactMap(\.uuid)
		InstallPackageRetention.shared.beginInstallation(for: uuid, protected: related)
	}

	@MainActor
	func finishInstallCleanup(for app: AppInfoPresentable) {
		guard app.isSigned, let uuid = app.uuid,
			let object = app as? NSManagedObject, !object.isDeleted else { return }
		let replace = UserDefaults.standard.object(forKey: "SignOs.autoDeleteOldVersions") as? Bool ?? true
		InstallPackageRetention.shared.installationEnded(for: uuid, replaceOldVersions: replace) { victimUUID, signed in
			if signed {
				let request: NSFetchRequest<Signed> = Signed.fetchRequest()
				request.predicate = NSPredicate(format: "uuid == %@", victimUUID)
				if let victim = (try? context.fetch(request))?.first, !AppOperations.isSourceManaged(victim) || AppOperations.isAllowed(victim) { deleteApp(for: victim) }
			} else {
				let request: NSFetchRequest<Imported> = Imported.fetchRequest()
				request.predicate = NSPredicate(format: "uuid == %@", victimUUID)
				if let victim = (try? context.fetch(request))?.first, !AppOperations.isSourceManaged(victim) || AppOperations.isAllowed(victim) { deleteApp(for: victim) }
			}
		}
	}

	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}
}

// MARK: - Helpers
struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
	
	var id: String {
		base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var source: URL? { get }
	var isSigned: Bool { get }
	
}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}
