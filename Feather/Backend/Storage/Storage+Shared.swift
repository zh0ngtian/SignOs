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
			if let url = getUuidDirectory(for: app) {
				if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
			}
			deleteSourceMetadata(for: app.uuid)
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
			saveContext()
        } catch {
            NSLog("SignOs package cleanup failed: %@", error.localizedDescription)
        }
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
