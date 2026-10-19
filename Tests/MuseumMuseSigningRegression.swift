import Foundation

@main struct MuseumMuseSigningRegression {
    static func main() throws {
        typealias Adapter = MuseumMuseAppGroupSigning
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            let result = try condition()
            precondition(result)
        }
        func writeInfo(_ url: URL, _ info: [String: Any]) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
        }
        func info(_ url: URL) throws -> [String: Any] {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Info.plist")), options: [], format: nil) as! [String: Any]
        }
        func fixture(mainGroup: String? = nil, widgetGroup: String? = nil, identifier: String = Adapter.bundleIdentifier) throws -> URL {
            let app = root.appendingPathComponent(UUID().uuidString + ".app")
            var main: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "App", "CFBundleVersion": "10"]
            var widget: [String: Any] = ["CFBundleIdentifier": identifier + ".widget", "CFBundleExecutable": "Widget",
                "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]]
            main[Adapter.runtimeGroupKey] = mainGroup
            widget[Adapter.runtimeGroupKey] = widgetGroup
            try writeInfo(app, main)
            try writeInfo(app.appendingPathComponent("PlugIns/Widget.appex"), widget)
            return app
        }
        func expectFailure(_ failure: Adapter.Failure, _ operation: () throws -> Void) throws {
            do { try operation(); preconditionFailure("Expected \(failure)") }
            catch let error as Adapter.Failure { precondition(error.localizedDescription == failure.localizedDescription) }
        }
        func signedExecutable(groups: [String]) throws -> Data {
            let xml = try PropertyListSerialization.data(fromPropertyList: [Adapter.entitlementKey: groups,
                "application-identifier": "TEAM.existing.signing.identity", "keychain-access-groups": ["TEAM.existing"]], format: .xml, options: 0)
            func word(_ value: UInt32, big: Bool) -> Data {
                Data((big ? [24, 16, 8, 0] : [0, 8, 16, 24]).map { UInt8(truncatingIfNeeded: value >> $0) })
            }
            var blob = word(0xfade0cc0, big: true) + word(UInt32(28 + xml.count), big: true) + word(1, big: true)
            blob += word(5, big: true) + word(20, big: true) + word(0xfade7171, big: true) + word(UInt32(8 + xml.count), big: true) + xml
            var macho = Data(repeating: 0, count: 32)
            macho.replaceSubrange(0..<4, with: word(0xfeedfacf, big: false))
            macho.replaceSubrange(16..<20, with: word(1, big: false))
            return macho + word(0x1d, big: false) + word(16, big: false) + word(48, big: false) + word(UInt32(blob.count), big: false) + blob
        }

        // Reproduce the actual unsigned 1.1.4 input with a multi-group profile.
        let app = try fixture()
        let plan = try Adapter.prepare(appURL: app, profileGroups: ["group.unrelated", Adapter.compatibilityGroup])!
        precondition(plan.group == Adapter.compatibilityGroup && plan.targets.count == 2)
        try plan.apply()
        for target in plan.targets {
            let values = try info(target.url)
            precondition(values[Adapter.runtimeGroupKey] as? String == Adapter.compatibilityGroup)
            precondition(values["CFBundleIdentifier"] as? String == target.identifier)
            try signedExecutable(groups: ["group.unrelated", plan.group]).write(to: target.url.appendingPathComponent(target.executable))
        }
        try check(try info(app)["CFBundleVersion"] as? String == "10")
        try plan.validateSigned()

        // An extension with missing group authorization must stop packaging.
        let widget = plan.targets[1]
        try signedExecutable(groups: ["group.unrelated"]).write(to: widget.url.appendingPathComponent(widget.executable))
        try expectFailure(.signedGroupMismatch) { try plan.validateSigned() }
        try signedExecutable(groups: [plan.group]).write(to: widget.url.appendingPathComponent(widget.executable))
        var changed = try info(widget.url); changed[Adapter.runtimeGroupKey] = "group.unrelated"
        try writeInfo(widget.url, changed)
        try expectFailure(.signedGroupMismatch) { try plan.validateSigned() }

        let native = try fixture()
        try check(try Adapter.prepare(appURL: native, profileGroups: [Adapter.originalGroup])!.group == Adapter.originalGroup)
        let declared = try fixture(mainGroup: "group.existing", widgetGroup: "group.existing")
        try check(try Adapter.prepare(appURL: declared, profileGroups: ["group.existing", Adapter.compatibilityGroup])!.group == "group.existing")
        let update = try fixture()
        try check(try Adapter.prepare(appURL: update, profileGroups: [Adapter.originalGroup, Adapter.compatibilityGroup],
            previousRuntimeGroup: Adapter.compatibilityGroup)!.group == Adapter.compatibilityGroup)
        try expectFailure(.conflictingGroups) {
            _ = try Adapter.prepare(appURL: declared, profileGroups: ["group.existing", Adapter.compatibilityGroup],
                previousRuntimeGroup: Adapter.compatibilityGroup)
        }
        try expectFailure(.unauthorizedGroup) {
            _ = try Adapter.prepare(appURL: update, profileGroups: [Adapter.compatibilityGroup], previousRuntimeGroup: "group.old")
        }
        let partial = try fixture(mainGroup: Adapter.compatibilityGroup)
        let partialPlan = try Adapter.prepare(appURL: partial, profileGroups: [Adapter.compatibilityGroup])!
        try partialPlan.apply()
        try check(try info(partial.appendingPathComponent("PlugIns/Widget.appex"))[Adapter.runtimeGroupKey] as? String == Adapter.compatibilityGroup)

        let unauthorized = try fixture()
        try expectFailure(.unauthorizedGroup) { _ = try Adapter.prepare(appURL: unauthorized, profileGroups: ["group.unrelated"]) }
        try check(try info(unauthorized)[Adapter.runtimeGroupKey] == nil)
        let conflicting = try fixture(mainGroup: Adapter.compatibilityGroup, widgetGroup: "group.other")
        try expectFailure(.conflictingGroups) { _ = try Adapter.prepare(appURL: conflicting, profileGroups: [Adapter.compatibilityGroup, "group.other"]) }
        let unsupportedExisting = try fixture(mainGroup: "group.old")
        try expectFailure(.unauthorizedGroup) { _ = try Adapter.prepare(appURL: unsupportedExisting, profileGroups: [Adapter.compatibilityGroup]) }
        let custom = try fixture()
        try expectFailure(.customEntitlementsMismatch) {
            _ = try Adapter.prepare(appURL: custom, profileGroups: [Adapter.compatibilityGroup], customEntitlements: [Adapter.entitlementKey: ["group.other"]])
        }
        try check(try Adapter.prepare(appURL: custom, profileGroups: [Adapter.compatibilityGroup],
            customEntitlements: [Adapter.entitlementKey: [Adapter.compatibilityGroup]]) != nil)
        let missingWidget = try fixture()
        try FileManager.default.removeItem(at: missingWidget.appendingPathComponent("PlugIns"))
        try expectFailure(.invalidPackage) { _ = try Adapter.prepare(appURL: missingWidget, profileGroups: [Adapter.compatibilityGroup]) }

        let other = try fixture(identifier: "example.other")
        try check(try Adapter.prepare(appURL: other, profileGroups: []) == nil)
        try check(try info(other)[Adapter.runtimeGroupKey] == nil)
        print("MuseumMuseSigningRegression passed: unsigned input, both targets, installed group preservation, profile/custom authorization, post-sign rejection, malformed package, unrelated app isolation")
    }
}
