import AltSourceKit
import Foundation

/// A source release in the upgrade range, independent of the version inside the IPA.
struct UpdateRelease: Identifiable, Equatable {
    let version: String
    let date: Date?
    let notes: String?

    var id: String { version }

    init(version: String, date: Date?, notes: String?) {
        self.version = version
        self.date = date
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = trimmed?.isEmpty == false ? trimmed : nil
    }

    static func history(app: ASRepository.App, installedVersion: String?, targetVersion: String) -> [Self] {
        let target = Self(version: targetVersion, date: app.currentDate?.date,
            notes: app.currentAppVersion?.localizedDescription ?? app.versionDescription)
        guard let installedVersion else { return [target] }
        var seen: Set<String> = [targetVersion]
        let intermediate = (app.versions ?? []).filter {
            AppVersion.compare($0.version, installedVersion) == .orderedDescending &&
            AppVersion.compare($0.version, targetVersion) == .orderedAscending &&
            seen.insert($0.version).inserted
        }.map { Self(version: $0.version, date: $0.date?.date, notes: $0.localizedDescription) }
        return [target] + intermediate.sorted {
            AppVersion.compare($0.version, $1.version) == .orderedDescending
        }
    }
}
