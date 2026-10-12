import Foundation

@main struct MachOEntitlementsRegression {
    static func main() throws {
        let values: [String: Any] = ["application-identifier": "PREFIX.vendor.assigned", "com.apple.developer.team-identifier": "TEAM", "keychain-access-groups": ["PREFIX.vendor.assigned"]]
        let xml = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        func word(_ value: UInt32, big: Bool) -> Data {
            let offsets = big ? [24, 16, 8, 0] : [0, 8, 16, 24]
            return Data(offsets.map { UInt8(truncatingIfNeeded: value >> $0) })
        }
        var blob = word(0xfade0cc0, big: true) + word(UInt32(28 + xml.count), big: true) + word(1, big: true)
        blob += word(5, big: true) + word(20, big: true) + word(0xfade7171, big: true) + word(UInt32(8 + xml.count), big: true) + xml
        var thin = Data(repeating: 0, count: 32)
        thin.replaceSubrange(0..<4, with: word(0xfeedfacf, big: false)); thin.replaceSubrange(16..<20, with: word(1, big: false))
        thin += word(0x1d, big: false) + word(16, big: false) + word(48, big: false) + word(UInt32(blob.count), big: false) + blob
        let decoded = MachOEntitlements.read(thin)!
        precondition(decoded["application-identifier"] as? String == "PREFIX.vendor.assigned")
        precondition(decoded["keychain-access-groups"] as? [String] == ["PREFIX.vendor.assigned"])
        for length in 0..<thin.count { precondition(MachOEntitlements.read(Data(thin.prefix(length))) == nil, "Truncated signature at \(length)") }
        var fat = word(0xcafebabe, big: true) + word(1, big: true) + word(0x0100000c, big: true) + word(0, big: true)
        fat += word(28, big: true) + word(UInt32(thin.count), big: true) + word(0, big: true) + thin
        precondition(MachOEntitlements.read(fat)?["application-identifier"] as? String == "PREFIX.vendor.assigned")
        var corrupt = thin; corrupt.replaceSubrange(36..<40, with: word(.max, big: false))
        precondition(MachOEntitlements.read(corrupt) == nil)
        print("MachOEntitlementsRegression passed: real entitlement slot, independent signing App ID, fat arm64, all truncations and invalid bounds")
    }
}
