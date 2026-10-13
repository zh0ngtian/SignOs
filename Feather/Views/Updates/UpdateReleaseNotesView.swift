import SwiftUI

struct UpdateReleaseNotesView: View {
    let releases: [UpdateRelease]
    let sourceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(releases) { release in
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text(verbatim: release.version)
                        .font(.subheadline.weight(.semibold))
                    // A single wrapping text keeps the date to the right of its source
                    // without compressing either field at accessibility text sizes.
                    Text(verbatim: sourceName + " · " + publicationText(release.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: release.notes ?? "未提供更新说明")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func publicationText(_ date: Date?) -> String {
        guard let date else { return "发布时间未知" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
