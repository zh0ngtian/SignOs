import Foundation

@MainActor final class Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

struct AltSource { var sourceURL: URL?; var identifier: String? }
protocol AppInfoPresentable {}
struct LocalApp: AppInfoPresentable {}
enum SourcePolicy {
    static func isEnabled(url: URL?, identifier: String?) -> Bool { true }
}
@MainActor enum SourceSynchronization {
    static var calls = 0
    static func synchronizeManagedSources(_ sources: [AltSource]) async throws -> [String] {
        calls += 1
        try Task.checkCancellation()
        return []
    }
}
@MainActor final class SourcesViewModel {
    static let shared = SourcesViewModel()
    func applySynchronizedRepositories(_ repositories: [Int]) {}
}
@MainActor final class UpdateManager {
    static let shared = UpdateManager()
    var updates: [Int: Int] = [:]
    var calls = 0
    var cancellations = 0
    var gate: Gate?
    var entered: Gate?
    var failNext = false
    func reset() {
        updates = [:]; calls = 0; cancellations = 0
        gate = nil; entered = nil; failNext = false
        SourceSynchronization.calls = 0
    }
    func checkForUpdates(sources: [AltSource], localApps: [any AppInfoPresentable],
                         synchronizeSources: @MainActor () async throws -> [String],
                         onSourcesSynchronized: @MainActor ([Int]) -> Void) async -> Bool {
        calls += 1
        let blocked = gate
        gate = nil
        entered?.open()
        await blocked?.wait()
        do {
            try Task.checkCancellation()
            _ = try await synchronizeSources()
            if failNext { failNext = false; return false }
            onSourcesSynchronized([])
            updates = [0: calls]
            return true
        } catch {
            cancellations += 1
            return false
        }
    }
}

@main struct AutoUpdateCheckRegression {
    @MainActor static var failures = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
    @MainActor static func main() async {
        let updates = UpdateManager.shared

        // View redraw/disappearance cancels its waiter while network work is suspended.
        updates.reset()
        let first = AutoUpdateManager(), entered = Gate(), release = Gate()
        updates.gate = release; updates.entered = entered
        let caller = Task { await first.checkNow(syncManagedSources: true) }
        await entered.wait()
        caller.cancel()
        release.open()
        let count = await caller.value
        expect(count == 1 && updates.cancellations == 0,
               "cancelling a refresh waiter must preserve the owned update check")
        expect(!first.isAutoChecking && first.lastCheckDate != nil, "completed check must clear progress and record success")

        // A second pull waits for the running check rather than returning stale results.
        updates.reset()
        let second = AutoUpdateManager(), entered2 = Gate(), release2 = Gate(), joined = Gate()
        updates.gate = release2; updates.entered = entered2
        let original = Task { await second.checkNow(syncManagedSources: true) }
        await entered2.wait()
        var duplicateFinished = false
        let duplicate = Task {
            joined.open()
            let count = await second.checkNow(syncManagedSources: true)
            duplicateFinished = true
            return count
        }
        await joined.wait()
        expect(!duplicateFinished, "duplicate refresh must wait for the active check")
        duplicate.cancel()
        release2.open()
        let originalCount = await original.value
        let duplicateCount = await duplicate.value
        expect(originalCount == 1 && duplicateCount == 1 && updates.calls == 1,
               "refresh waiters must share one successful check")
        _ = await second.checkNow(syncManagedSources: true)
        expect(updates.calls == 2, "a completed task must not suppress a later fresh check")

        // Manual refresh must still synchronize when it arrives during an automatic check.
        updates.reset()
        let third = AutoUpdateManager(), entered3 = Gate(), release3 = Gate(), requested = Gate()
        updates.gate = release3; updates.entered = entered3
        let automatic = Task { await third.checkNow(notifyWhenClean: false) }
        await entered3.wait()
        let manual = Task {
            requested.open()
            return await third.checkNow(notifyWhenClean: false, syncManagedSources: true)
        }
        await requested.wait()
        manual.cancel()
        release3.open()
        _ = await automatic.value
        let manualCount = await manual.value
        expect(manualCount == 1 && updates.calls == 2 && SourceSynchronization.calls == 1,
               "manual refresh must run managed synchronization after an active automatic check")

        // Failure must release ownership so retry can run.
        updates.reset()
        let fourth = AutoUpdateManager()
        updates.failNext = true
        _ = await fourth.checkNow(syncManagedSources: true)
        let retry = await fourth.checkNow(syncManagedSources: true)
        expect(retry == 1 && updates.calls == 2 && !fourth.isAutoChecking,
               "failed checks must allow a subsequent retry")
        if failures > 0 { print("AutoUpdateCheckRegression failed: \(failures)"); exit(1) }
        print("AutoUpdateCheckRegression passed: cancellation, coalescing, manual synchronization, retry")
    }
}
