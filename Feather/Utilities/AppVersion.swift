import Foundation

/// Source dates describe publication, not version order. Unknown formats stay manual.
enum AppVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = parse(lhs), let b = parse(rhs) else { return lhs == rhs ? .orderedSame : nil }
        for index in 0..<max(a.core.count, b.core.count) {
            let result = number(index < a.core.count ? a.core[index] : "0", index < b.core.count ? b.core[index] : "0")
            if result != .orderedSame { return result }
        }
        if a.pre.isEmpty && b.pre.isEmpty { return .orderedSame }
        if a.pre.isEmpty { return .orderedDescending }
        if b.pre.isEmpty { return .orderedAscending }
        for index in 0..<min(a.pre.count, b.pre.count) {
            let x = a.pre[index], y = b.pre[index]
            let xn = x.allSatisfy(\.isNumber), yn = y.allSatisfy(\.isNumber)
            let result: ComparisonResult
            if xn && yn { result = number(x, y) }
            else if xn != yn { result = xn ? .orderedAscending : .orderedDescending }
            else { result = x.compare(y, options: .literal) }
            if result != .orderedSame { return result }
        }
        return a.pre.count == b.pre.count ? .orderedSame : (a.pre.count < b.pre.count ? .orderedAscending : .orderedDescending)
    }

    private static func number(_ a: String, _ b: String) -> ComparisonResult {
        let x = String(a.drop(while: { $0 == "0" })), y = String(b.drop(while: { $0 == "0" }))
        if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
        return x.compare(y, options: .literal)
    }

    private static func parse(_ value: String) -> (core: [String], pre: [String])? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let release = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = release.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard core.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let pre = parts.count > 1 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else { return nil }
        return (core, pre)
    }
}
