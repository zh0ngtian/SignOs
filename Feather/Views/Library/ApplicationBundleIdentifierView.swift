import SwiftUI

struct ApplicationBundleIdentifierView: View {
    let originalIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var savedIdentifier: String?

    private var normalizedIdentifier: String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        AppBundleIdentifierPreferences.validationError(for: normalizedIdentifier)
    }

    var body: some View {
        Form {
            Section("签名使用的 Bundle ID") {
                TextField("com.example.app", text: $identifier, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier("application.bundleIdentifier")
                if let validationError {
                    Text(validationError).font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                Text(originalIdentifier).textSelection(.enabled)
                    .font(.callout).foregroundStyle(.secondary)
                Button("恢复原始 Bundle ID") { identifier = originalIdentifier }
                    .disabled(normalizedIdentifier == originalIdentifier)
            } header: {
                Text("原始 Bundle ID")
            } footer: {
                Text("无需管理 Token，仅保存在本机，不修改软件源。从下次签名开始生效，同一应用的不同版本和软件源共用。修改 Bundle ID 后，iOS 会将其视为另一个应用。")
            }
        }
        .navigationTitle("Bundle ID 配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    AppBundleIdentifierPreferences.shared.save(normalizedIdentifier, for: originalIdentifier)
                    UpdateManager.shared.sourceAvailabilityChanged(localApps: AppOperations.packages())
                    AutoUpdateManager.shared.updateBadgeFromState()
                    dismiss()
                }
                .disabled(validationError != nil || normalizedIdentifier == savedIdentifier)
            }
        }
        .onAppear {
            savedIdentifier = AppBundleIdentifierPreferences.shared.configuredIdentifier(for: originalIdentifier)
            identifier = savedIdentifier ?? originalIdentifier
        }
    }
}
