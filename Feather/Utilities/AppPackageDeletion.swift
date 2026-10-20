import Foundation

/// Explicit local deletion keeps source subscriptions and their preferences intact.
@MainActor
enum AppPackageDeletion {
    enum Target {
        case application(String)
        case package(String)
    }

    struct Request: Identifiable {
        let id = UUID()
        let target: Target
        let name: String
        let count: Int

        init(application: ManagedApplication) {
            target = .application(application.id)
            name = application.primary.name ?? application.id
            count = application.packages.count
        }

        init?(package: any AppInfoPresentable) {
            guard let uuid = package.uuid else { return nil }
            target = .package(uuid)
            name = package.name ?? package.identifier ?? "应用"
            count = 1
        }

        var title: String {
            switch target {
            case .application: "删除这个应用的本地包？"
            case .package: "删除这个本地包？"
            }
        }

        var message: String {
            let content: String
            switch target {
            case .application: content = "将删除“\(name)”的全部 \(count) 个本地包和历史版本。"
            case .package: content = "将删除“\(name)”的这个本地包及其本地记录。"
            }
            return content + "软件源订阅会保留，不会卸载桌面应用。之后可从软件源重新下载或手动导入。"
        }
    }

    static func remove(_ target: Target) -> StorageCleanup.Report {
        // Resolve again after confirmation so newly started work cannot lose its input.
        let packages: [any AppInfoPresentable]
        switch target {
        case .application(let identifier):
            packages = AppInventory.applications(AppOperations.packages()).first { $0.id == identifier }?.packages ?? []
        case .package(let uuid):
            packages = AppOperations.packages().filter { $0.uuid == uuid }
        }
        let jobs = AutoSignManager.shared.queue + (AutoSignManager.shared.currentJob.map { [$0] } ?? [])
        let protected = InstallPackageRetention.shared.protectedPackageUUIDs
        for app in packages {
            let busy = SourceAccessManager.shared.isInUse(app.uuid)
                || app.identifier.map { SourceAccessManager.shared.hasActiveApplication($0) } == true
                || jobs.contains { $0.appUUID == app.uuid || (app.identifier != nil && $0.appIdentifier == app.identifier) }
                || DownloadManager.shared.downloads.contains { download in
                    download.targetAppUUID == app.uuid || download.sourceProvenance.map {
                        SourceSubscriptionIdentity.bundleIdentifier(from: $0.sourceAppIdentifier) == app.identifier
                    } == true
                }
            if busy {
                return .init(failures: ["这个应用正在下载、签名或安装，请等待当前任务结束后重试。"])
            }
            if let uuid = app.uuid, protected.contains(uuid) {
                return .init(failures: ["这个本地包仍用于待完成的安装，已保留供重试。请完成安装后再删除。"])
            }
        }
        let report = StorageCleanup.remove(packages) { try Storage.shared.deleteAppReportingErrors(for: $0) }
        UpdateManager.shared.sourceAvailabilityChanged(localApps: AppOperations.packages())
        AutoUpdateManager.shared.updateBadgeFromState()
        return report
    }
}
