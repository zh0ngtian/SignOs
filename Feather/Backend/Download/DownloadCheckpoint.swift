import Foundation

struct DownloadCheckpoint: Codable, Sendable, Identifiable {
    enum Phase: String, Codable, Sendable { case partial, paused, failed, requiresRestart, ready }
    enum Mode: String, Codable, Sendable { case segmented, single }
    enum Validator: Codable, Equatable, Sendable {
        case etag(String), lastModified(String)
        var value: String { switch self { case .etag(let value), .lastModified(let value): value } }
    }
    struct Representation: Codable, Equatable, Sendable {
        var length: Int64
        var validator: Validator?

        static func validator(for response: HTTPURLResponse) -> Validator? {
            if let tag = response.value(forHTTPHeaderField: "ETag") {
                let value = tag.trimmingCharacters(in: .whitespaces)
                let scalars = Array(value.unicodeScalars)
                guard scalars.count >= 2, scalars.first?.value == 34, scalars.last?.value == 34,
                      scalars.dropFirst().dropLast().allSatisfy({ $0.value == 33 || (35...126).contains($0.value) || (128...255).contains($0.value) }) else { return nil }
                return .etag(value)
            }
            // RFC 9110: a date validator used with If-Range must be strong.
            guard let modified = response.value(forHTTPHeaderField: "Last-Modified"),
                  let date = response.value(forHTTPHeaderField: "Date"),
                  modified.count <= 128, date.count <= 128,
                  !modified.contains(where: { $0.isNewline }), !date.contains(where: { $0.isNewline }) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            guard let lastModified = formatter.date(from: modified), let serverDate = formatter.date(from: date),
                  serverDate.timeIntervalSince(lastModified) >= 60 else { return nil }
            return .lastModified(modified)
        }

        func matches(_ response: HTTPURLResponse) -> Bool {
            switch validator {
            case .etag(let value): return response.value(forHTTPHeaderField: "ETag") == value
            case .lastModified(let value): return response.value(forHTTPHeaderField: "Last-Modified") == value
            case nil: return false
            }
        }
    }
    struct Part: Sendable {
        let index: Int
        let lower: Int64
        let upper: Int64
        var length: Int64 { upper - lower + 1 }
    }

    var schemaVersion = 1
    let id: UUID
    let url: URL
    let context: Data
    var fileName: String
    var representation: Representation?
    var partCount = 1
    var mode: Mode = .segmented
    var phase: Phase = .paused
    var message: String?
    var restartInSingleMode = false
    var completedSHA256: String?

    func parts() -> [Part] {
        guard let total = representation?.length, total > 0, (1...4).contains(partCount), total >= Int64(partCount) else { return [] }
        let count = Int64(partCount), base = total / count, extra = total % count
        return (0..<partCount).map { index in
            let i = Int64(index), lower = base * i + min(i, extra)
            return Part(index: index, lower: lower, upper: lower + base + (i < extra ? 1 : 0) - 1)
        }
    }

    static func contentRange(_ value: String?) -> (lower: Int64, upper: Int64, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { return nil }
        let interval = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard interval.count == 2, let lower = Int64(interval[0]), let upper = Int64(interval[1]),
              lower >= 0, upper >= lower, upper < total else { return nil }
        return (lower, upper, total)
    }
}
