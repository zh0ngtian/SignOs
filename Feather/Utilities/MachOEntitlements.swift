import Foundation

/// Read the actual XML entitlement slot, never infer an App ID from a display name.
enum MachOEntitlements {
    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return read(data)
    }

    static func read(_ data: Data) -> [String: Any]? {
        let bytes = data
        func integer(_ offset: Int, _ count: Int, big: Bool) -> UInt64? {
            guard offset >= 0, count <= bytes.count, offset <= bytes.count - count else { return nil }
            let slice = bytes[offset..<(offset + count)]
            if big { return slice.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            return slice.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func word(_ offset: Int, big: Bool = false) -> Int? { integer(offset, 4, big: big).flatMap(Int.init(exactly:)) }
        var start = 0, length = bytes.count
        if let magic = word(0, big: true), magic == 0xcafebabe || magic == 0xcafebabf {
            let wide = magic == 0xcafebabf
            guard let count = word(4, big: true), count > 0, count <= 64 else { return nil }
            var chosen: (Int, Int)?
            for index in 0..<count {
                let record = 8 + index * (wide ? 32 : 20)
                guard let cpu = word(record, big: true),
                    let offset = integer(record + 8, wide ? 8 : 4, big: true).flatMap(Int.init(exactly:)),
                    let size = integer(record + (wide ? 16 : 12), wide ? 8 : 4, big: true).flatMap(Int.init(exactly:)),
                    offset >= 0, size >= 0, offset <= bytes.count, size <= bytes.count - offset else { return nil }
                if chosen == nil || cpu == 0x0100000c { chosen = (offset, size) }
                if cpu == 0x0100000c { break }
            }
            guard let chosen else { return nil }; (start, length) = chosen
        }
        guard let magic = word(start), magic == 0xfeedfacf || magic == 0xfeedface,
            let count = word(start + 16), count <= 4096 else { return nil }
        var command = start + (magic == 0xfeedfacf ? 32 : 28)
        for _ in 0..<count {
            guard let kind = word(command), let size = word(command + 4), size >= 8,
                command <= start + length, size <= start + length - command else { return nil }
            defer { command += size }
            guard kind == 0x1d else { continue }
            guard size >= 16, let offset = word(command + 8), let blobSize = word(command + 12),
                offset <= length, blobSize >= 12, blobSize <= length - offset else { return nil }
            let blob = start + offset
            guard word(blob, big: true) == 0xfade0cc0, let slots = word(blob + 8, big: true), slots <= 64,
                12 + slots * 8 <= blobSize else { return nil }
            for index in 0..<slots {
                let slot = blob + 12 + index * 8
                guard word(slot, big: true) == 5 else { continue }
                guard let relative = word(slot + 4, big: true), relative <= blobSize - 8 else { return nil }
                let entry = blob + relative
                guard word(entry, big: true) == 0xfade7171, let size = word(entry + 4, big: true),
                    size >= 8, size <= blobSize - relative else { return nil }
                let xml = Data(bytes[(entry + 8)..<(entry + size)])
                return (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any]
            }
        }
        return nil
    }
}
