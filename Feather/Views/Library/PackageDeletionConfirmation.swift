import SwiftUI

private struct PackageDeletionConfirmation: ViewModifier {
    @Binding var request: AppPackageDeletion.Request?
    @State private var errorMessage: String?
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion {
        let request: AppPackageDeletion.Request
        let protection: InstallPackageRetention.DeletionProtection
    }

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
            .alert("放弃安装重试并删除？", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { pending in
                Button("放弃重试并删除", role: .destructive) {
                    pendingDeletion = nil
                    remove(pending.request, abandoning: pending.protection)
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { _ in
                Text("这些本地包仍被待完成的安装保留。确认后将删除所选本地包，并放弃使用这些包重试安装。软件源订阅和桌面应用会保留。")
            }
            .alert("删除未完成", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func remove(_ request: AppPackageDeletion.Request,
                        abandoning protection: InstallPackageRetention.DeletionProtection? = nil) {
        self.request = nil
        let report = AppPackageDeletion.remove(request.target, abandoning: protection)
        if let current = report.requiresConfirmation {
            if protection == nil {
                pendingDeletion = PendingDeletion(request: request, protection: current)
            } else {
                errorMessage = "待安装记录已发生变化，本次未删除任何包。请重新发起删除并确认。"
            }
            return
        }
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
