// Production queue processing with controlled signing/archive/install boundaries.
import Foundation
import CoreData
import Combine
import UIKit
import SafariServices
import Darwin

protocol AppInfoPresentable {
    var uuid: String? { get }; var identifier: String? { get }; var name: String? { get }; var isSigned: Bool { get }
}
@objc(Signed) final class Signed: NSManagedObject, AppInfoPresentable {
    @NSManaged var uuid: String?; @NSManaged var identifier: String?; @NSManaged var name: String?
    @NSManaged var date: Date?; @NSManaged var version: String?
    var isSigned: Bool { true }
    static func fetchRequest() -> NSFetchRequest<Signed> { NSFetchRequest(entityName: "Signed") }
}
@objc(Imported) final class Imported: NSManagedObject, AppInfoPresentable {
    @NSManaged var uuid: String?; @NSManaged var identifier: String?; @NSManaged var name: String?
    var isSigned: Bool { false }
    static func fetchRequest() -> NSFetchRequest<Imported> { NSFetchRequest(entityName: "Imported") }
}
final class CertificatePair: NSObject {
    var uuid = "certificate"; var revoked = false; var expiration: Date?; var isDefault = false
}
struct Metadata { let sourceVersionID: String }
@MainActor final class Storage {
    static let shared = Storage()
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    var metadata: [String: Metadata] = [:]
    var cleaned: [String] = []
    init() {
        let model = NSManagedObjectModel()
        model.entities = [("Signed", ["uuid", "identifier", "name", "version", "date"]),
                          ("Imported", ["uuid", "identifier", "name"])].map { name, keys in
            let entity = NSEntityDescription(); entity.name = name; entity.managedObjectClassName = name
            entity.properties = keys.map { key in
                let property = NSAttributeDescription(); property.name = key
                property.attributeType = key == "date" ? .dateAttributeType : .stringAttributeType
                property.isOptional = true; return property
            }
            return entity
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context.persistentStoreCoordinator = coordinator
    }
    func sourceMetadata(for app: AppInfoPresentable) -> Metadata? { app.uuid.flatMap { metadata[$0] } }
    func sourceMetadata(for uuid: String) -> Metadata? { metadata[uuid] }
    func finishInstallCleanup(for app: AppInfoPresentable) { cleaned.append(app.uuid!) }
    func getCertificate(from app: AppInfoPresentable) -> CertificatePair? { nil }
    func getAllCertificates() -> [CertificatePair] { [] }
    func getCertificate(for index: Int) -> CertificatePair? { nil }
}
struct Options { enum SigningOption { case `default`, adhoc }; var signingOption = SigningOption.adhoc; var appIdentifier = ""; var appName = "" }
@MainActor final class OptionsManager { static let shared = OptionsManager(); var options = Options() }
@MainActor enum FR {
    static var signCalls = 0; static var completion: ((Error?) -> Void)?
    static func signPackageFile(_ app: AppInfoPresentable, using: Options, icon: String?, certificate: CertificatePair?, completion: @escaping (Error?) -> Void) {
        signCalls += 1; self.completion = completion
    }
}
@MainActor final class AutoUpdateManager {
    static let shared = AutoUpdateManager()
    func notify(title: String, body: String, identifier: String, category: String? = nil) {}
    func updateBadgeFromState() {}
}
@MainActor final class ActivityLog {
    enum Kind { case failed, renewed, updated, installed }
    static let shared = ActivityLog()
    func log(_ kind: Kind, app: String, detail: String? = nil) {}
}
@MainActor final class InstallPackageRetention {
    static let shared = InstallPackageRetention()
    func schedule(for uuid: String, signed: [String], imported: [String]) {}
}
final class InstallerStatusViewModel { init(isIdevice: Bool) {} }
@MainActor final class ArchiveHandler {
    static var fastestCompressionOverride = false
    static var entered: [String] = []; static var waiting: CheckedContinuation<Void, Never>?
    let app: AppInfoPresentable
    init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) { self.app = app }
    func move() async throws {
        precondition(Self.waiting == nil, "Update All must not run concurrent installers")
        Self.entered.append(app.uuid!)
        await withCheckedContinuation { Self.waiting = $0 }
    }
    func archive() async throws -> URL { URL(fileURLWithPath: "/fixture.ipa") }
    static func finish() { let continuation = waiting; waiting = nil; continuation!.resume() }
}
final class InstallationProxy {
    init(viewModel: InstallerStatusViewModel) {}
    func install(at url: URL, suspend: Bool) async throws {}
}
@MainActor final class ServerInstaller {
    var packageUrl: URL?; var pageEndpoint = URL(string: "https://example.com")!; var iTunesLink = "https://example.com"
    init(app: Signed, viewModel: InstallerStatusViewModel) throws {}
    func getServerMethod() -> Int { 0 }
}
extension UIApplication { static func topViewController() -> UIViewController? { nil } }

@main struct AutoSignManagerRegression {
    @MainActor static func main() async throws {
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() { precondition(Date() < deadline, "Queue timed out"); try await Task.sleep(nanoseconds: 1_000_000) }
        }
        func signed(_ uuid: String, identifier: String = "fixture.app") -> Signed {
            let app = Signed(context: Storage.shared.context)
            app.uuid = uuid; app.identifier = identifier; app.name = uuid; app.date = Date(); app.version = "2"
            return app
        }
        UserDefaults.standard.set(1, forKey: "Feather.installationMethod")
        UserDefaults.standard.set(false, forKey: "SignOs.installChargingOnly")
        UserDefaults.standard.set(false, forKey: "SignOs.autoSignEnabled")
        let manager = AutoSignManager.shared
        let first = signed("first"), second = signed("second", identifier: "fixture.second")
        Storage.shared.metadata["first"] = Metadata(sourceVersionID: "source|first|2")
        Storage.shared.metadata["second"] = Metadata(sourceVersionID: "source|second|2")
        manager.enqueueInstall(app: first); manager.enqueueInstall(app: first); manager.enqueueInstall(app: second)
        precondition(manager.queue.count == 2, "Repeated Update All must deduplicate queued installs")
        try await waitUntil { ArchiveHandler.entered.count == 1 }
        precondition(manager.currentJob?.appUUID == "first" && manager.queue.count == 1 && FR.signCalls == 0)
        manager.enqueueInstall(app: first)
        precondition(manager.queue.count == 1, "Repeated click during installation must not enqueue it again")
        ArchiveHandler.finish()
        try await waitUntil { ArchiveHandler.entered.count == 2 }
        precondition(manager.currentJob?.appUUID == "second" && FR.signCalls == 0)
        ArchiveHandler.finish()
        try await waitUntil { manager.currentJob == nil && manager.queue.isEmpty }
        precondition(Storage.shared.cleaned == ["first", "second"])
        precondition(manager.confirmedInstallUUIDs == ["first", "second"])

        let imported = Imported(context: Storage.shared.context)
        imported.uuid = "imported"; imported.identifier = "fixture.imported"; imported.name = "imported"
        Storage.shared.metadata["imported"] = Metadata(sourceVersionID: "source|imported|2")
        manager.enqueue(app: imported, reason: .autoUpdate, force: true)
        manager.enqueue(app: imported, reason: .autoUpdate, force: true)
        try await waitUntil { FR.completion != nil }
        precondition(FR.signCalls == 1, "Downloaded imports sign once even when Auto-Sign is off")
        let produced = signed("produced", identifier: "fixture.imported")
        Storage.shared.metadata["produced"] = Storage.shared.metadata["imported"]
        manager.enqueueInstall(app: produced)
        precondition(manager.queue.isEmpty, "Signed result of an in-flight job must not be installed twice")
        FR.completion!(nil); FR.completion = nil
        try await waitUntil { ArchiveHandler.entered.count == 3 }
        ArchiveHandler.finish()
        try await waitUntil { manager.currentJob == nil }
        precondition(ArchiveHandler.entered == ["first", "second", "produced"] && FR.signCalls == 1)
        print("AutoSignManagerRegression passed: direct install without signing, serial queue, queued/active deduplication, imported signing and in-flight result reuse")
        fflush(stdout)
    }
}
