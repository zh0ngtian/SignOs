import Foundation

@main struct AppVersionRegression {
    static func main() {
        let cases: [(String, String, ComparisonResult?)] = [
            ("1.10", "1.9", .orderedDescending), ("1.0.0", "1", .orderedSame),
            ("v2.0", "1.99", .orderedDescending), ("1.0", "1.0-beta.9", .orderedDescending),
            ("1.0-beta.10", "1.0-beta.2", .orderedDescending), ("1.0-beta", "1.0-rc", .orderedAscending),
            ("1.0+20261012", "1.0+20261011", .orderedSame), ("1.0", "2.0", .orderedAscending),
            ("001.002", "1.2", .orderedSame), ("99999999999999999999999999", "2", .orderedDescending),
            ("", "1.0", nil), ("latest", "1.0", nil), ("1..0", "1.0", nil), ("1.0-", "1.0", nil)
        ]
        for (a, b, expected) in cases { precondition(AppVersion.compare(a, b) == expected, "\(a) vs \(b)") }
        print("AppVersionRegression passed: numeric ordering, prereleases, build metadata, unknown formats and integer overflow")
    }
}
