import SwiftUI

private struct PackageDeletionConfirmation: ViewModifier {
    @Binding var request: AppPackageDeletion.Request?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert(request?.title ?? "确认删除", isPresented: Binding(
                get: { request != nil }, set: { if !$0 { request = nil } }
            ), presenting: request) { request in
                Button("删除", role: .destructive) { remove(request) }
                Button("取消", role: .cancel) { self.request = nil }
            } message: { request in
                Text(request.message)
            }
            .alert("删除未完成", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func remove(_ request: AppPackageDeletion.Request) {
        self.request = nil
        let report = AppPackageDeletion.remove(request.target)
        if !report.failures.isEmpty {
            errorMessage = "已删除 \(report.removed) 个本地包，未删除的包可重试。\n" + report.failures.joined(separator: "\n")
        }
    }
}

extension View {
    func packageDeletionConfirmation(_ request: Binding<AppPackageDeletion.Request?>) -> some View {
        modifier(PackageDeletionConfirmation(request: request))
    }
}
