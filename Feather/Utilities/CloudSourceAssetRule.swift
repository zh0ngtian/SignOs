import Foundation

enum CloudSourceAssetRule {
    static func suggestedPattern(for name: String, candidateNames: [String]) -> String {
        let pattern = name.replacingOccurrences(of: "v?[0-9]+(?:\\.[0-9]+){1,3}", with: "*", options: .regularExpression)
        // Version-like numbers can also identify variants. Keep the exact name if
        // generalizing it would select another IPA from the same release.
        let matches = candidateNames.filter { self.matches(pattern: pattern, name: $0) }
        return matches == [name] ? pattern : name
    }

    static func matches(pattern: String, name: String) -> Bool {
        let expression = pattern.map { character -> String in
            switch character {
            case "*": return ".*"
            case "?": return "."
            default: return NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
        return name.range(of: "^" + expression + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func validationMessage(pattern: String, selectedName: String, candidateNames: [String]) -> String? {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return "请填写这个 IPA 的后续版本匹配规则。" }
        guard pattern.count <= 200, !pattern.contains("/"), !pattern.contains("\\") else { return "匹配规则不能包含路径，且最多 200 个字符。" }
        guard matches(pattern: pattern, name: selectedName) else { return "匹配规则未包含所选 IPA，请调整规则。" }
        guard candidateNames.filter({ matches(pattern: pattern, name: $0) }).count == 1 else {
            return "匹配规则包含多个 IPA，请缩小范围以分别订阅。"
        }
        return nil
    }
}
