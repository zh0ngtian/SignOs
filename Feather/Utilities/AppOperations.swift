import Foundation
import CoreData
import UIKit

@MainActor
enum AppOperations {
    private static var deferredUpdates: [String: (AppUpdate, Bool, Bool, String?)] = [:]
    static func resumeDeferredUpdates() {
        let pending = deferredUpdates
        deferredUpdates = [:]
        for (_, item) in pending { update(item.0, automatic: item.1, allowReplacement: item.2, downloadID: item.3) }
    }
    static func packages() -> [any AppInfoPresentable] {
        let signed = (try? Storage.shared.context.fetch(Signed.fetchRequest())) ?? []
        let imported = (try? Storage.shared.context.fetch(Imported.fetchRequest())) ?? []
        return signed.map { $0 as any AppInfoPresentable } + imported.map { $0 as any AppInfoPresentable }
    }

    static func signedResult(for app: any AppInfoPresentable) -> Signed? {
        if let input = app.uuid, let output = SourceAccessManager.shared.signedResults[input] {
            return packages().compactMap { $0 as? Signed }.first { $0.uuid == output }
        }
        return installed(for: app.identifier)
    }

    static func installed(for identifier: String?) -> Signed? {
        guard let identifier else { return nil }
        return packages().compactMap { $0 as? Signed }.filter { $0.identifier == identifier }
            .max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    static func isSourceManaged(_ app: any AppInfoPresentable) -> Bool {
        Storage.shared.sourceMetadata(for: app) != nil || app.source != nil
    }

    static func sourceStatus(_ app: any AppInfoPresentable) -> String? {
        let metadata = Storage.shared.sourceMetadata(for: app)
        let url = metadata?.sourceRepositoryURL ?? app.source
        let identifier = metadata?.sourceRepositoryIdentifier
        let key = metadata?.sourceAppIdentifier ?? app.identifier ?? ""
        if SourcePolicy.isSubscriptionDeleted(url: url, identifier: identifier, appIdentifier: key) { return "订阅已删除，等待清理" }
        if !SourcePolicy.isEnabled(url: url, identifier: identifier) { return "来源已禁用" }
        return nil
    }

    static func isAllowed(_ app: any AppInfoPresentable) -> Bool { sourceStatus(app) == nil }

    static func sourceName(_ app: any AppInfoPresentable) -> String {
        Storage.shared.sourceMetadata(for: app)?.sourceRepositoryName ?? (app.source?.host ?? "手动导入")
    }

    static func isValid(_ certificate: CertificatePair) -> Bool {
        !certificate.revoked && (certificate.expiration.map { $0 > Date() } ?? true)
    }

    static func signingIdentity(for certificate: CertificatePair) -> SigningIdentity? {
        guard let profile = Storage.shared.getProvisionFileDecoded(for: certificate),
            let prefix = profile.ApplicationIdentifierPrefix?.first ?? profile.TeamIdentifier.first else { return nil }
        return SigningIdentity(prefix: prefix, teams: Set(profile.TeamIdentifier),
            applicationIdentifier: profile.Entitlements?["application-identifier"]?.value as? String,
            keychainGroups: profile.Entitlements?["keychain-access-groups"]?.value as? [String] ?? [],
            appGroups: profile.Entitlements?["com.apple.security.application-groups"]?.value as? [String] ?? [])
    }

    static func currentIdentity(for app: any AppInfoPresentable) -> SigningIdentity? {
        guard let signed = installed(for: app.identifier) else { return nil }
        if let data = signed.signingIdentityData, let identity = try? JSONDecoder().decode(SigningIdentity.self, from: data) { return identity }
        return signedIdentity(for: signed)
    }

    static func signedIdentity(for app: any AppInfoPresentable) -> SigningIdentity? {
        guard let directory = Storage.shared.getAppDirectory(for: app),
            let executable = Bundle(url: directory)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            let entitlements = MachOEntitlements.read(directory.appendingPathComponent(executable)),
            let application = entitlements["application-identifier"] as? String,
            let prefix = application.split(separator: ".").first,
            let team = entitlements["com.apple.developer.team-identifier"] as? String else { return nil }
        return SigningIdentity(prefix: String(prefix), teams: [team], applicationIdentifier: application,
            keychainGroups: entitlements["keychain-access-groups"] as? [String] ?? [],
            appGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? [], bundleIdentifier: app.identifier)
    }

    static func preserveSigningIdentities() {
        for app in packages().compactMap({ $0 as? Signed }) where app.signingIdentityData == nil {
            if let identity = signedIdentity(for: app) {
                app.signingIdentityData = try? JSONEncoder().encode(identity)
            }
        }
        Storage.shared.saveContext()
    }

    static func certificate(for app: any AppInfoPresentable) -> CertificatePair? {
        let current = installed(for: app.identifier)
        let previous = currentIdentity(for: app)
        func eligible(_ cert: CertificatePair) -> Bool {
            guard isValid(cert) else { return false }
            guard current != nil else { return true }
            guard let previous, let replacement = signingIdentity(for: cert) else { return false }
            return replacement.canReplace(previous, bundle: app.identifier)
        }
        if let existing = current?.certificate ?? Storage.shared.getCertificate(from: app), eligible(existing) { return existing }
        let certs = Storage.shared.getAllCertificates().filter(eligible)
        let selected = Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "feather.selectedCert"))
        return selected.flatMap { eligible($0) ? $0 : nil } ?? certs.first { $0.isDefault } ?? certs.first
    }

    static func compatible(_ old: CertificatePair, _ new: CertificatePair, bundleIdentifier: String? = nil) -> Bool {
        if old.uuid == new.uuid { return true }
        guard let previous = signingIdentity(for: old), let replacement = signingIdentity(for: new) else { return false }
        return replacement.canReplace(previous, bundle: bundleIdentifier)
    }

    static func signingError(for app: any AppInfoPresentable, certificate: CertificatePair?, targetIdentifier: String? = nil) -> String? {
        guard !SourceAccessManager.shared.hasActiveApplication(app.identifier ?? "") else { return "这个应用正在处理，请等待当前任务结束。" }
        if let status = sourceStatus(app) { return status + (status == "来源已禁用" ? "，请先启用软件源。" : "，此订阅的包不能继续签名或安装。") }
        if let certificate {
            guard isValid(certificate) else { return "所选证书已过期或撤销，请选择有效证书。" }
            if targetIdentifier == nil || targetIdentifier == app.identifier, installed(for: app.identifier) != nil {
                guard let previous = currentIdentity(for: app), let replacement = signingIdentity(for: certificate) else {
                    return "无法验证原应用的签名身份，请恢复原证书资料后再更换，或通过签名选项使用新的 Bundle ID 安装。"
                }
                guard replacement.canReplace(previous, bundle: app.identifier) else {
                    return "新证书的签名身份与当前应用不兼容，无法直接覆盖安装。请保留原包和数据，选择兼容证书。"
                }
            }
        }
        return nil
    }

    static func showError(_ message: String) {
        UIAlertController.showAlertWithOk(title: "无法继续", message: message)
    }

    static func obtain(url: URL, id: String, provenance: SourceAppProvenance?) {
        guard let provenance, let version = provenance.sourceAppVersion else {
            _ = DownloadManager.shared.startDownload(from: url, id: id, sourceProvenance: provenance)
            return
        }
        let bundle = SourceSubscriptionIdentity.bundleIdentifier(from: provenance.sourceAppIdentifier)
        guard let baseline = AppInventory.applications(packages()).first(where: { $0.id == bundle })?.primary,
            let uuid = baseline.uuid else {
            _ = DownloadManager.shared.startDownload(from: url, id: id, sourceProvenance: provenance)
            return
        }
        let candidate = AppUpdate(id: uuid, localUUID: uuid, localVersion: baseline.version, remoteVersion: version,
            appName: provenance.sourceAppName ?? baseline.name ?? bundle, bundleIdentifier: bundle,
            downloadURL: url, sourceURL: provenance.sourceRepositoryURL, sourceProvenance: provenance,
            whatsNew: nil,
            releaseHistory: [UpdateRelease(version: version, date: provenance.sourceAppVersionDate, notes: nil)],
            managedIdentifier: baseline.identifier)
        UpdateManager.shared.selectCandidate(candidate, for: bundle)
        update(candidate, allowReplacement: true, downloadID: id)
    }

    static func matchesSourcePackage(_ package: any AppInfoPresentable, provenance: SourceAppProvenance?) -> Bool {
        guard let provenance else { return true }
        guard let metadata = Storage.shared.sourceMetadata(for: package), let url = metadata.sourceRepositoryURL else { return false }
        return metadata.sourceAppIdentifier == provenance.sourceAppIdentifier && metadata.sourceAppVersion == provenance.sourceAppVersion &&
            SourceRepositoryIdentity.matches(storedURL: url, storedIdentifier: metadata.sourceRepositoryIdentifier,
                currentURL: provenance.sourceRepositoryURL, currentIdentifier: provenance.sourceRepositoryIdentifier)
    }

    @discardableResult
    static func update(_ update: AppUpdate, automatic: Bool = false, allowReplacement: Bool = false, downloadID: String? = nil) -> Bool {
        let origin = update.sourceProvenance
        guard SourcePolicy.isEnabled(url: update.sourceURL, identifier: origin.sourceRepositoryIdentifier),
            !SourcePolicy.isSubscriptionDeleted(url: update.sourceURL, identifier: origin.sourceRepositoryIdentifier, appIdentifier: origin.sourceAppIdentifier) else { return false }
        let apps = packages()
        let baseline = apps.first { $0.uuid == update.localUUID } ?? installed(for: update.managedIdentifier ?? update.bundleIdentifier)
        if !allowReplacement, let baseline {
            let version = Storage.shared.sourceMetadata(for: baseline)?.sourceAppVersion ?? baseline.version ?? ""
            guard AppVersion.compare(update.remoteVersion, version) == .orderedDescending else { return false }
        }
        if let job = AutoSignManager.shared.currentJob,
            Storage.shared.sourceMetadata(for: job.appUUID)?.sourceVersionID == origin.sourceVersionID { return false }
        if DownloadManager.shared.downloads.contains(where: { $0.sourceProvenance?.sourceVersionID == origin.sourceVersionID && $0.targetAppUUID == baseline?.uuid }) { return false }
        let targetIdentifier = baseline?.identifier ?? update.bundleIdentifier
        if AutoSignManager.shared.currentJob?.appIdentifier == targetIdentifier ||
            SourceAccessManager.shared.hasActiveApplication(targetIdentifier) ||
            DownloadManager.shared.downloads.contains(where: { $0.targetAppUUID == update.localUUID || $0.sourceProvenance.map { SourceSubscriptionIdentity.bundleIdentifier(from: $0.sourceAppIdentifier) == update.bundleIdentifier } == true }) {
            deferredUpdates[targetIdentifier] = (update, automatic, allowReplacement, downloadID)
            return false
        }
        let target = baseline.flatMap { certificate(for: $0) }
        let cached = UpdateManager.shared.downloadedApp(for: update, among: apps, isPackageAvailable: {
            guard let directory = Storage.shared.getAppDirectory(for: $0) else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("Info.plist").path)
        })
        if let cached {
            if let signed = cached as? Signed, signed.certificate?.uuid == target?.uuid,
                signed.certificate.map(isValid) ?? true,
                (signed.date ?? .distantPast) >= (baseline?.date ?? .distantPast) {
                AutoSignManager.shared.enqueueInstall(app: signed)
            } else {
                var options = OptionsManager.shared.options
                if let baselineID = baseline?.identifier, baselineID != update.bundleIdentifier { options.appIdentifier = baselineID; options.appName = baseline?.name }
                AutoSignManager.shared.enqueue(app: cached, reason: .autoUpdate, certificate: target, options: options, force: !automatic)
            }
            return true
        }
        let id = downloadID ?? "\(automatic ? SignOsAuto.downloadPrefix : "SignOsManualUpdate")_\(update.localUUID)"
        _ = DownloadManager.shared.startDownload(from: update.downloadURL, id: id, sourceProvenance: origin, targetAppUUID: baseline?.uuid ?? update.localUUID)
        return true
    }
}
