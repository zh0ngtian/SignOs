import Foundation

/// Owns update checks independently of the SwiftUI task awaiting their result.
@MainActor
final class UpdateCheckCoordinator {
    private var activeTask: Task<Int, Never>?
    private var synchronizesManagedSources = false

    func run(
        syncManagedSources: Bool,
        operation: @escaping @MainActor () async -> Int
    ) async -> Int {
        if let task = activeTask {
            let needsSynchronization = syncManagedSources && !synchronizesManagedSources
            let result = await task.value
            // An automatic feed check cannot satisfy a manual remote-sync request.
            if needsSynchronization {
                return await run(syncManagedSources: syncManagedSources, operation: operation)
            }
            return result
        }

        synchronizesManagedSources = syncManagedSources
        let task = Task { @MainActor in
            defer {
                // Clear ownership before waking waiters, so a requested follow-up can start.
                activeTask = nil
                synchronizesManagedSources = false
            }
            return await operation()
        }
        activeTask = task
        return await task.value
    }
}
