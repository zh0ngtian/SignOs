import Foundation

actor DownloadTransferLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if active < limit { active += 1; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { active -= 1 }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
