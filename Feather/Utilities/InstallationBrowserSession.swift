import Combine
import IDeviceSwift
import SafariServices
import UIKit

/// Controls only the installation trampoline, never the server or package lifetime.
@MainActor
final class InstallationBrowserSession: ObservableObject {
    @Published var isPresented = false
    private var shouldClose = false
    private var enteredBackground = false
    private var observations = Set<AnyCancellable>()

    init(viewModel: InstallerStatusViewModel) {
        viewModel.$status
            .map { status -> Bool in
                switch status {
                case .sendingPayload, .installing, .completed, .broken: return true
                default: return false
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldClose in
                guard let self, self.isPresented, shouldClose else { return }
                self.shouldClose = true
                self.closeIfNeeded()
            }
            .store(in: &observations)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isPresented else { return }
                self.enteredBackground = true
            }
            .store(in: &observations)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.shouldClose = self.shouldClose || self.enteredBackground
                self.closeIfNeeded()
            }
            .store(in: &observations)
    }

    func present() {
        shouldClose = false
        enteredBackground = false
        isPresented = true
    }

    private func closeIfNeeded() {
        // System confirmation can make the app inactive without entering the background.
        guard isPresented, shouldClose, UIApplication.shared.applicationState == .active else { return }
        isPresented = false
    }
}

/// UIKit presentation for automatic installs; manual installs bind the same session to a sheet.
@MainActor
final class InstallationBrowserPresentation: NSObject, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    let controller: SFSafariViewController
    let session: InstallationBrowserSession
    private var observation: AnyCancellable?
    private var onFinish: (() -> Void)?

    init(url: URL, viewModel: InstallerStatusViewModel, onFinish: @escaping () -> Void) {
        controller = SFSafariViewController(url: url)
        session = InstallationBrowserSession(viewModel: viewModel)
        self.onFinish = onFinish
        super.init()
        controller.delegate = self
    }

    func present(from presenter: UIViewController) {
        session.present()
        observation = session.$isPresented.dropFirst().sink { [weak self] presented in
            if !presented { self?.close() }
        }
        presenter.present(controller, animated: true) { [weak self] in
            guard let self else { return }
            // A payload request may arrive before the presentation animation finishes.
            if !self.session.isPresented { self.close() }
        }
        controller.presentationController?.delegate = self
    }

    private func close() {
        guard !controller.isBeingPresented, !controller.isBeingDismissed else { return }
        guard controller.presentingViewController != nil else { finish(); return }
        controller.dismiss(animated: true) { [weak self] in self?.finish() }
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in self?.finish() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish()
    }

    private func finish() {
        observation = nil
        session.isPresented = false
        let completion = onFinish
        onFinish = nil
        completion?()
    }
}
