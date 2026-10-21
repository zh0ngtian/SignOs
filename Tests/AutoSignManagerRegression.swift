// Production queue processing with controlled signing/archive/install boundaries.
import Foundation
import CoreData
import Combine
import UIKit
import SafariServices
import Darwin

protocol AppInfoPresentable {
    var uuid: String? { get }; var identifier: String? { get }; var name: String? { get }; var isSigned: Bool { get }
    var originalIdentifier: String? { get }
    var date: Date? { get }
}
extension AppInfoPresentable { var originalIdentifier: String? { nil }; var date: Date? { nil } }
@objc(Signed) final class Signed: NSManagedObject, AppInfoPresentable {
    var originalIdentifier: String?
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
    var protected: [String] = []
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
    func protectPackagesAwaitingInstallation(for app: AppInfoPresentable) { protected.append(app.uuid!) }
    func getCertificate(from app: AppInfoPresentable) -> CertificatePair? { nil }
    func getAllCertificates() -> [CertificatePair] { [] }
    func getCertificate(for index: Int) -> CertificatePair? { nil }
}
struct Options { enum SigningOption { case `default`, adhoc }; var signingOption = SigningOption.adhoc; var appIdentifier: String?; var appName: String?; var originalIdentifier: String?; var post_installAppAfterSigned = false }
@MainActor final class OptionsManager { static let shared = OptionsManager(); var options = Options() }
@MainActor enum AppOperations {
    static var disabled = Set<String>()
    static func isAllowed(_ app: AppInfoPresentable) -> Bool { !disabled.contains(app.uuid ?? "") }
    static func packages() -> [any AppInfoPresentable] { [] }
    static func signedResult(for app: AppInfoPresentable) -> Signed? {
        guard let input = app.uuid, let output = SourceAccessManager.shared.signedResults[input] else { return nil }
        return (try? Storage.shared.context.fetch(Signed.fetchRequest()))?.first { $0.uuid == output }
    }
    static func resumeDeferredUpdates() {}
    static func certificate(for app: AppInfoPresentable, targetIdentifier: String? = nil) -> CertificatePair? { CertificatePair() }
    static func signingError(for app: AppInfoPresentable, certificate: CertificatePair?, targetIdentifier: String? = nil) -> String? { nil }
}
@MainActor final class SourceAccessManager {
    static let shared = SourceAccessManager()
    var signedResults: [String: String] = [:]
    var suppressed = Set<String>()
    func wasSuppressed(_ uuid: String?) -> Bool { uuid.map(suppressed.contains) ?? false }
    func cleanupDeletedSubscriptions() {}
    func beginUse(_ app: AppInfoPresentable) {}
    func hasActiveApplication(_ identifier: String) -> Bool { false }
    func endUse(_ app: AppInfoPresentable) {}
}
@MainActor final class UpdateManager {
    static let shared = UpdateManager()
    func dismissUpdate(withLocalUUID: String) {}
    func sourceAvailabilityChanged(localApps: [any AppInfoPresentable]? = nil) {}
}
@MainActor enum FR {
    static var signCalls = 0; static var completion: ((Error?) -> Void)?
    static var lastOptions: Options?
    static func signPackageFile(_ app: AppInfoPresentable, using: Options, icon: String?, certificate: CertificatePair?, completion: @escaping (Error?) -> Void) {
        signCalls += 1; self.completion = completion; lastOptions = using
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
final class InstallerStatusViewModel { enum Status { case none, completed, broken }; @Published var status = Status.none; init(isIdevice: Bool) {} }
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
    let id = UUID()
    var packageUrl: URL?; var pageEndpoint = URL(string: "https://example.com")!; var iTunesLink = "https://example.com"
    init(app: Signed, viewModel: InstallerStatusViewModel) throws {}
    func getServerMethod() -> Int { 0 }
}
@MainActor final class InstallationBrowserPresentation {
    init(url: URL, viewModel: InstallerStatusViewModel, onDismiss: @escaping () -> Void) {}
    func present(from controller: UIViewController) {}
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
        precondition(Storage.shared.protected == ["first", "second"], "Direct installs register durable package protection before preparing archives")
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
        let interrupted = Imported(context: Storage.shared.context)
        interrupted.uuid = "interrupted"; interrupted.identifier = "fixture.interrupted"; interrupted.name = "interrupted"
        let queued = signed("cancelled-queue", identifier: "fixture.cancelled")
        let unaffected = signed("unaffected", identifier: "fixture.unaffected")
        manager.enqueue(app: interrupted, force: true)
        try await waitUntil { FR.completion != nil }
        manager.enqueueInstall(app: queued); manager.enqueueInstall(app: unaffected)
        manager.cancelPending { $0.uuid == interrupted.uuid || $0.uuid == queued.uuid }
        precondition(manager.queue.map(\.appUUID) == [unaffected.uuid!])
        _ = signed("late-result", identifier: "fixture.interrupted")
        FR.completion!(nil); FR.completion = nil
        try await waitUntil { ArchiveHandler.entered.count == 4 }
        precondition(ArchiveHandler.entered.last == "unaffected", "Interrupted signing must not install or resume, including after reenabling")
        ArchiveHandler.finish()
        try await waitUntil { manager.currentJob == nil }
        precondition(!ArchiveHandler.entered.contains("late-result") && !ArchiveHandler.entered.contains("cancelled-queue"))
        let preferences = AppBundleIdentifierPreferences.shared
        preferences.save("fixture.personal", for: imported.identifier!)
        manager.enqueueImported(uuid: imported.uuid!, force: true)
        try await waitUntil { FR.completion != nil }
        precondition(FR.lastOptions?.appIdentifier == "fixture.personal", "Automatic imports use the saved per-app identity")
        precondition(FR.lastOptions?.originalIdentifier == imported.identifier)
        manager.cancelPending { $0.uuid == imported.uuid }
        FR.completion!(nil); FR.completion = nil
        try await waitUntil { manager.currentJob == nil }
        manager.cloneApp(app: imported)
        try await waitUntil { FR.completion != nil }
        let cloneOptions = FR.lastOptions!
        precondition(cloneOptions.appIdentifier != imported.identifier)
        precondition(cloneOptions.originalIdentifier == cloneOptions.appIdentifier, "A clone owns an independent persistent preference")
        let clone = signed("clone-baseline", identifier: cloneOptions.appIdentifier!)
        clone.originalIdentifier = cloneOptions.originalIdentifier
        let cloneUpdate = AppOperations.signingOptions(for: imported, updating: clone)
        precondition(cloneUpdate.appIdentifier == clone.identifier, "Updating a clone does not use its parent's preference")
        preferences.save("fixture.personal.clone", for: clone.originalIdentifier!)
        let customizedClone = AppOperations.signingOptions(for: clone)
        precondition(customizedClone.appIdentifier == "fixture.personal.clone")
        precondition(AppOperations.signingOptions(for: imported).appIdentifier == "fixture.personal")
        let customized = signed("customized-baseline", identifier: "fixture.personal")
        customized.originalIdentifier = imported.identifier
        precondition(AppOperations.signingOptions(for: customized).appIdentifier == "fixture.personal", "Manual re-signing keeps the original preference key")
        preferences.save(imported.identifier!, for: imported.identifier!)
        precondition(AppOperations.signingOptions(for: customized).appIdentifier == imported.identifier, "Reset applies even when the input is a custom signed package")
        manager.cancelPending { $0.uuid == imported.uuid }
        FR.completion!(nil); FR.completion = nil
        try await waitUntil { manager.currentJob == nil }

        // Follow the source manual-sign handoff with Auto-Sign and the global post-install option off.
        let sourceImport = Imported(context: Storage.shared.context)
        sourceImport.uuid = "source-input"; sourceImport.identifier = "fixture.source"; sourceImport.name = "Source App"
        var draft = Options(); draft.appIdentifier = "fixture.unrelated.global.rule"
        let originalOptions = try ManualSigningFlow.prepare(draft, for: sourceImport, purpose: .sourceInstall)
        precondition(originalOptions.appIdentifier == sourceImport.identifier, "Source signing defaults to the original ID")
        precondition(preferences.configuredIdentifier(for: "fixture.source") == nil, "Signing does not create a preference outside source settings")
        preferences.save("fixture.source.personal", for: "fixture.source")
        let prepared = try ManualSigningFlow.prepare(draft, for: sourceImport, purpose: .sourceInstall)
        precondition(!prepared.post_installAppAfterSigned)
        precondition(prepared.appIdentifier == "fixture.source.personal" && prepared.originalIdentifier == "fixture.source")
        precondition(AppBundleIdentifierPreferences().identifier(for: "fixture.source") == prepared.appIdentifier, "Source signing reads the persisted source setting")
        precondition(AppInventory.applications([sourceImport])[0].id == prepared.appIdentifier)
        preferences.save("fixture..broken", for: "fixture.source")
        do { _ = try ManualSigningFlow.prepare(draft, for: sourceImport, purpose: .sourceInstall); preconditionFailure("Invalid stored IDs must not start signing") }
        catch {}
        preferences.save(prepared.appIdentifier!, for: "fixture.source")
        do { _ = try ManualSigningFlow.installationResult(for: sourceImport, options: prepared, purpose: .sourceInstall); preconditionFailure("Missing output must not use an older package") }
        catch {}
        let sourceOutput = signed("source-output", identifier: prepared.appIdentifier!)
        sourceOutput.originalIdentifier = prepared.originalIdentifier
        SourceAccessManager.shared.signedResults[sourceImport.uuid!] = sourceOutput.uuid!
        let grouped = AppInventory.applications([sourceImport, sourceOutput])
        precondition(grouped.count == 1 && grouped[0].packages.count == 2 && grouped[0].installed?.uuid == sourceOutput.uuid, "The original input belongs to the target app without another pending card")
        let originalSigned = signed("original-identity", identifier: "fixture.source")
        precondition(AppInventory.applications([sourceImport, sourceOutput, originalSigned, clone]).count == 3, "Different signed identities and clones stay independent")
        var temporary = prepared; temporary.appIdentifier = "fixture.temporary"
        _ = try ManualSigningFlow.prepare(temporary, for: sourceImport, purpose: .sign)
        precondition(preferences.identifier(for: "fixture.source") == prepared.appIdentifier, "Ordinary signing does not change the saved source setting")
        let manualResult = try ManualSigningFlow.installationResult(for: sourceImport, options: prepared, purpose: .sign)
        precondition(manualResult == nil, "Ordinary manual signing honors its post-install setting")
        do { _ = try ManualSigningFlow.installationResult(for: sourceImport, options: temporary, purpose: .sourceInstall); preconditionFailure("Wrong target must not install") }
        catch {}
        SourceAccessManager.shared.suppressed.insert(sourceImport.uuid!)
        let suppressedResult = try ManualSigningFlow.installationResult(for: sourceImport, options: prepared, purpose: .sourceInstall)
        precondition(suppressedResult == nil, "A disabled then reenabled source cannot resume the cancelled handoff")
        SourceAccessManager.shared.suppressed.removeAll()
        AppOperations.disabled.insert(sourceOutput.uuid!)
        let disabledResult = try ManualSigningFlow.installationResult(for: sourceImport, options: prepared, purpose: .sourceInstall)
        precondition(disabledResult == nil)
        AppOperations.disabled.removeAll()
        let result = try ManualSigningFlow.installationResult(for: sourceImport, options: prepared, purpose: .sourceInstall)!
        let previousCalls = FR.signCalls
        manager.enqueueInstall(app: result)
        try await waitUntil { ArchiveHandler.entered.last == sourceOutput.uuid }
        precondition(manager.currentJob?.appUUID == sourceOutput.uuid && manager.currentJob?.appIdentifier == prepared.appIdentifier && FR.signCalls == previousCalls, "Install the exact custom-ID output without signing again")
        ArchiveHandler.finish()
        try await waitUntil { manager.currentJob == nil }
        preferences.save("fixture.source.next", for: "fixture.source")
        let moved = AppInventory.applications([sourceImport, sourceOutput])
        precondition(moved.count == 2 && moved.first { $0.id == "fixture.source.next" }?.installed == nil, "A changed preference must not relabel an existing signature as installed")
        print("AutoSignManagerRegression passed: direct/serial/deduplicated installs, source signing reads local settings and installs exact output, original defaults, invalid/missing/wrong output protection, disabled-source suppression, merged input grouping and independent signed identities/clones")
        fflush(stdout)
    }
}
