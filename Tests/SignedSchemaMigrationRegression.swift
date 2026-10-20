import Foundation
import CoreData

@main struct SignedSchemaMigrationRegression {
    static func main() throws {
        let newModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!.copy() as! NSManagedObjectModel
        for entity in newModel.entities { entity.managedObjectClassName = "NSManagedObject" }
        let oldModel = newModel.copy() as! NSManagedObjectModel
        let signedEntity = oldModel.entitiesByName["Signed"]!
        signedEntity.properties = signedEntity.properties.filter { !["signingIdentityData", "originalIdentifier"].contains($0.name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Feather.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let signed = NSEntityDescription.insertNewObject(forEntityName: "Signed", into: context)
        for (key, value) in ["uuid": "old-signed", "identifier": "com.example.app", "name": "Existing app", "version": "1.0"] { signed.setValue(value, forKey: key) }
        let date = Date(timeIntervalSince1970: 100)
        signed.setValue(date, forKey: "date")
        let imported = NSEntityDescription.insertNewObject(forEntityName: "Imported", into: context)
        for (key, value) in ["uuid": "old-import", "identifier": "com.example.app", "name": "Downloaded app", "version": "1.2"] { imported.setValue(value, forKey: key) }
        imported.setValue(date, forKey: "date")
        let metadata = NSEntityDescription.insertNewObject(forEntityName: "AppSourceMetadata", into: context)
        for (key, value) in ["appUUID": "old-signed", "appKind": "signed", "sourceAppIdentifier": "com.example.app", "sourceVersionID": "source|1.0"] { metadata.setValue(value, forKey: key) }
        metadata.setValue(date, forKey: "createdAt"); metadata.setValue(date, forKey: "updatedAt")
        metadata.setValue(URL(string: "https://example.com/source.json")!, forKey: "sourceRepositoryURL")
        try context.save(); context.reset(); try coordinator.remove(store)
        let migrated = NSPersistentStoreCoordinator(managedObjectModel: newModel)
        _ = try migrated.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); reader.persistentStoreCoordinator = migrated
        let retained = try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: "Signed"))
        precondition(retained.count == 1 && retained[0].value(forKey: "uuid") as? String == "old-signed")
        precondition(retained[0].value(forKey: "date") as? Date == date)
        precondition(retained[0].value(forKey: "version") as? String == "1.0")
        precondition(retained[0].value(forKey: "signingIdentityData") == nil)
        precondition(retained[0].value(forKey: "originalIdentifier") == nil)
        let importedCount = try reader.count(for: NSFetchRequest<NSManagedObject>(entityName: "Imported")); precondition(importedCount == 1)
        let metadataCount = try reader.count(for: NSFetchRequest<NSManagedObject>(entityName: "AppSourceMetadata")); precondition(metadataCount == 1)
        let identity = SigningIdentity(prefix: "PREFIX", teams: ["TEAM"], applicationIdentifier: "PREFIX.*", keychainGroups: ["PREFIX.*"])
        retained[0].setValue(try JSONEncoder().encode(identity), forKey: "signingIdentityData")
        retained[0].setValue("com.example.original", forKey: "originalIdentifier")
        try reader.save(); reader.reset()
        let reloaded = try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: "Signed"))[0]
        let decoded = try JSONDecoder().decode(SigningIdentity.self, from: reloaded.value(forKey: "signingIdentityData") as! Data)
        precondition(decoded.canReplace(identity, bundle: "com.example.app"))
        precondition(reloaded.value(forKey: "originalIdentifier") as? String == "com.example.original")
        print("SignedSchemaMigrationRegression passed: old signed/imported/source records and signing dates survive lightweight migration; signing identity and original Bundle ID persist")
    }
}
