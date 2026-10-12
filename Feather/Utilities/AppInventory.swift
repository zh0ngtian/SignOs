import Foundation

struct ManagedApplication: Identifiable {
    let id: String
    let packages: [any AppInfoPresentable]
    var installed: (any AppInfoPresentable)? { packages.first { $0.isSigned } }
    var primary: any AppInfoPresentable { installed ?? packages[0] }
}

enum AppInventory {
    static func applications(_ packages: [any AppInfoPresentable]) -> [ManagedApplication] {
        Dictionary(grouping: packages, by: { $0.identifier ?? $0.uuid ?? "unknown" })
            .map { key, values in
                ManagedApplication(id: key, packages: values.sorted {
                    if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                    return ($0.uuid ?? "") < ($1.uuid ?? "")
                })
            }
            .sorted { ($0.primary.name ?? $0.id).localizedStandardCompare($1.primary.name ?? $1.id) == .orderedAscending }
    }
}
