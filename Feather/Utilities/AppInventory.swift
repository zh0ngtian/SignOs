import Foundation

struct ManagedApplication: Identifiable {
    let id: String
    let packages: [any AppInfoPresentable]
    var installed: (any AppInfoPresentable)? { packages.first { $0.isSigned } }
    var primary: any AppInfoPresentable { installed ?? packages[0] }
}

@MainActor
enum AppInventory {
    static func groupIdentifier(for app: any AppInfoPresentable) -> String {
        if !app.isSigned, let identifier = app.identifier {
            return AppBundleIdentifierPreferences.shared.identifier(for: identifier)
        }
        return app.identifier ?? app.uuid ?? "unknown"
    }

    static func applications(_ packages: [any AppInfoPresentable], sourceUpdateDates: [String: Date] = [:]) -> [ManagedApplication] {
        Dictionary(grouping: packages, by: groupIdentifier)
            .map { key, values in
                ManagedApplication(id: key, packages: values.sorted {
                    if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                    return ($0.uuid ?? "") < ($1.uuid ?? "")
                })
            }
            .sorted {
                let leftDate = sourceUpdateDates[$0.id]
                let rightDate = sourceUpdateDates[$1.id]
                if leftDate != rightDate {
                    if let leftDate, let rightDate { return leftDate > rightDate }
                    return leftDate != nil
                }
                let comparison = ($0.primary.name ?? $0.id).localizedStandardCompare($1.primary.name ?? $1.id)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }
}
