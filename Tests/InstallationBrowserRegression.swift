import Combine
import IDeviceSwift
import SafariServices
import SwiftUI
import UIKit

@MainActor
private struct ManualBrowserHarness: View {
    @ObservedObject var session: InstallationBrowserSession
    let url: URL

    var body: some View {
        Text("SignOs 原生安装页面")
            .sheet(isPresented: $session.isPresented) {
                SafariRepresentableView(url: url).ignoresSafeArea()
            }
    }
}

@main
@MainActor
final class InstallationBrowserRegression: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var browser: InstallationBrowserPresentation?
    private var checks = 0
    private let url = URL(string: "http://127.0.0.1:18764/install")!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: Text("SignOs 原生应用页面"))
        window.rootViewController?.view.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            do {
                try await run()
                print("InstallationBrowserRegression passed: \(checks) scenarios")
                exit(0)
            } catch {
                print("InstallationBrowserRegression failed: \(error)")
                exit(1)
            }
        }
        return true
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "BrowserRegression.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func flushEvents() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: message, code: 1) }
        checks += 1
    }

    private func snapshot(_ name: String) throws {
        guard let window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func showAutomatic(_ model: InstallerStatusViewModel) async throws -> InstallationBrowserPresentation {
        let presentation = InstallationBrowserPresentation(url: url, viewModel: model) { [weak self] in
            self?.browser = nil
        }
        browser = presentation
        presentation.present(from: window!.rootViewController!)
        try await waitUntil { presentation.controller.view.window != nil && !presentation.controller.isBeingPresented }
        return presentation
    }

    private func run() async throws {
        try await waitUntil { UIApplication.shared.applicationState == .active }
        let root = window!.rootViewController!
        let model = InstallerStatusViewModel(status: .ready, isIdevice: false)
        let first = try await showAutomatic(model)
        model.status = .sendingManifest
        await flushEvents()
        try check(first.session.isPresented, "Manifest must preserve confirmation page")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flushEvents()
        try check(first.session.isPresented, "Temporary inactivity must preserve confirmation page")
        try snapshot("automatic-before")
        model.status = .sendingPayload
        try await waitUntil { root.presentedViewController == nil && browser == nil }
        try check({ if case .sendingPayload = model.status { return true }; return false }(), "Closing must not change installation status")
        try snapshot("automatic-after-payload")

        model.status = .ready
        let second = try await showAutomatic(model)
        // Explicit retries are allowed; returning from the background closes only this browser.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { root.presentedViewController == nil }
        try check(!second.session.isPresented, "Background return must close residual installation page")

        for status: InstallerStatusViewModel.InstallerStatus in [.installing, .completed(.success(())), .broken(NSError(domain: "test", code: 1))] {
            model.status = .ready
            let presentation = try await showAutomatic(model)
            model.status = status
            try await waitUntil { root.presentedViewController == nil }
            try check(!presentation.session.isPresented, "Terminal or installing status must close page")
        }

        model.status = .ready
        let fast = InstallationBrowserPresentation(url: url, viewModel: model) { [weak self] in self?.browser = nil }
        browser = fast
        fast.present(from: root)
        model.status = .sendingPayload
        try await waitUntil { root.presentedViewController == nil && browser == nil }
        try check(!fast.session.isPresented, "Payload during presentation animation must close page")

        model.status = .ready
        let cancelled = try await showAutomatic(model)
        cancelled.safariViewControllerDidFinish(cancelled.controller)
        await flushEvents()
        try await waitUntil { browser == nil }
        try check(!cancelled.session.isPresented, "Done must release browser observations")
        cancelled.controller.dismiss(animated: false)
        try await waitUntil { root.presentedViewController == nil }

        let unrelated = SFSafariViewController(url: url)
        root.present(unrelated, animated: false)
        try await waitUntil { root.presentedViewController === unrelated && !unrelated.isBeingPresented }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flushEvents()
        try check(root.presentedViewController === unrelated, "Unrelated browser must remain open")
        unrelated.dismiss(animated: false)
        try await waitUntil { root.presentedViewController == nil }

        model.status = .ready
        let session = InstallationBrowserSession(viewModel: model)
        let host = UIHostingController(rootView: ManualBrowserHarness(session: session, url: url))
        window!.rootViewController = host
        session.present()
        try await waitUntil { host.presentedViewController != nil && !host.presentedViewController!.isBeingPresented }
        try snapshot("manual-before")
        model.status = .sendingPayload
        try await waitUntil { host.presentedViewController == nil }
        try check(!session.isPresented, "Manual sheet must close on payload")
        try snapshot("manual-after-payload")
        model.status = .ready
        session.present()
        try await waitUntil { host.presentedViewController != nil && !host.presentedViewController!.isBeingPresented }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { host.presentedViewController == nil }
        try check(!session.isPresented, "Manual sheet must close on background return")
        try snapshot("manual-after-return")
    }
}
