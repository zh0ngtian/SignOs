import Foundation

/// MuseumMuse reads its runtime group from Info.plist, independently of the
/// signature. Keep that value aligned for the app and every Widget extension.
enum MuseumMuseAppGroupSigning {
    static let bundleIdentifier = "tech.zh0ngtian.MuseumMuse"
    static let runtimeGroupKey = "MuseumAppGroupIdentifier"
    static let entitlementKey = "com.apple.security.application-groups"
    static let originalGroup = "group.tech.zh0ngtian.MuseumMuse"
    // The existing MuseumMuse private OTA channel uses this group and namespace.
    // It is an explicit compatibility identity, never an arbitrary profile group.
    static let compatibilityGroup = "group.363da22903f0409e.5"

    enum Failure: LocalizedError {
        case invalidPackage
        case conflictingGroups
        case unauthorizedGroup
        case customEntitlementsMismatch
        case signingFailed
        case signedGroupMismatch

        var errorDescription: String? {
            switch self {
            case .invalidPackage:
                "博物女神安装包缺少有效的主 App 或小组件，无法配置共享存储。"
            case .conflictingGroups:
                "博物女神的 App 与小组件共享组不一致，已停止签名以保留原有数据。"
            case .unauthorizedGroup:
                "当前描述文件未授权博物女神使用的共享组，请选择支持原共享组的证书。"
            case .customEntitlementsMismatch:
                "自定义权限文件未包含博物女神使用的共享组，无法让 App 与小组件共享刷新结果。"
            case .signingFailed:
                "博物女神签名未成功，无法验证小组件共享存储。"
            case .signedGroupMismatch:
                "签名后的博物女神 App 或小组件未获授权访问同一共享组，已停止生成安装包。"
            }
        }
    }

    struct Target {
        let url: URL
        let identifier: String
        let executable: String
        var infoURL: URL { url.appendingPathComponent("Info.plist") }
    }

    struct Plan {
        let group: String
        let targets: [Target]

        func apply() throws {
            for target in targets {
                var info = try MuseumMuseAppGroupSigning.readInfo(target.url)
                info[runtimeGroupKey] = group
                let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                try data.write(to: target.infoURL, options: .atomic)
            }
        }

        func validateSigned() throws {
            for target in targets {
                let info = try MuseumMuseAppGroupSigning.readInfo(target.url)
                guard info["CFBundleIdentifier"] as? String == target.identifier,
                      info[runtimeGroupKey] as? String == group,
                      let entitlements = MachOEntitlements.read(target.url.appendingPathComponent(target.executable)),
                      let groups = entitlements[entitlementKey] as? [String],
                      groups.contains(group) else { throw Failure.signedGroupMismatch }
            }
        }
    }

    static func prepare(appURL: URL, profileGroups: [String], customEntitlements: [String: Any]? = nil,
                        previousRuntimeGroup: String? = nil) throws -> Plan? {
        let main = try readInfo(appURL)
        guard main["CFBundleIdentifier"] as? String == bundleIdentifier else { return nil }
        var targets = [try target(appURL, info: main)]
        let plugins = appURL.appendingPathComponent("PlugIns", isDirectory: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "appex" {
            let info = try readInfo(url)
            guard (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
                    == "com.apple.widgetkit-extension" else { continue }
            let widget = try target(url, info: info)
            guard widget.identifier.hasPrefix(bundleIdentifier + ".") else { throw Failure.invalidPackage }
            targets.append(widget)
        }
        guard targets.count > 1 else { throw Failure.invalidPackage }

        var declared = Set<String>()
        for target in targets {
            let info = try readInfo(target.url)
            if let value = info[runtimeGroupKey] {
                guard let group = value as? String, group.hasPrefix("group."), group.count > 6 else {
                    throw Failure.conflictingGroups
                }
                declared.insert(group)
            }
        }
        if let previousRuntimeGroup {
            guard previousRuntimeGroup.hasPrefix("group."), previousRuntimeGroup.count > 6 else {
                throw Failure.conflictingGroups
            }
            declared.insert(previousRuntimeGroup)
        }
        guard declared.count <= 1 else { throw Failure.conflictingGroups }
        let group: String
        if let existing = declared.first {
            group = existing
        } else if profileGroups.contains(originalGroup) {
            group = originalGroup
        } else {
            group = compatibilityGroup
        }
        guard profileGroups.contains(group) else { throw Failure.unauthorizedGroup }
        if let customEntitlements,
           !(customEntitlements[entitlementKey] as? [String] ?? []).contains(group) {
            throw Failure.customEntitlementsMismatch
        }
        return Plan(group: group, targets: targets)
    }

    private static func target(_ url: URL, info: [String: Any]) throws -> Target {
        guard let identifier = info["CFBundleIdentifier"] as? String,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, (executable as NSString).lastPathComponent == executable else {
            throw Failure.invalidPackage
        }
        return Target(url: url, identifier: identifier, executable: executable)
    }

    private static func readInfo(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = value as? [String: Any] else { throw Failure.invalidPackage }
        return info
    }
}
