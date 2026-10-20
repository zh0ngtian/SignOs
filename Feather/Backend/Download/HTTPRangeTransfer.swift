import Foundation
import os

/// URLSession callbacks and file writes stay off the UI actor. Every mutable
/// session/context field is protected by this lock; no unchecked conformance.
final class HTTPRangeTransfer: NSObject, URLSessionDataDelegate {
    struct Request: Sendable {
        let url: URL
        var destination: URL?
        var existingBytes: Int64 = 0
        var range: DownloadCheckpoint.Part?
        var representation: DownloadCheckpoint.Representation?
        var probe = false
    }
    struct Receipt: Sendable {
        let response: HTTPURLResponse
        let receivedBytes: Int64
    }
    private struct Context: Sendable {
        let id: UUID
        let request: Request
        let task: URLSessionDataTask
        let continuation: CheckedContinuation<Receipt, Error>
        let progress: @Sendable (Int64, Int64) -> Void
        var response: HTTPURLResponse?
        var handle: FileHandle?
        var received: Int64 = 0
        var expected: Int64 = 0
        var error: Error?
    }
    private struct State: Sendable {
        var session: URLSession?
        var contexts: [Int: Context] = [:]
        var cancelled = Set<UUID>()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        state.withLock { $0.session = session }
    }

    func invalidate() { state.withLock { $0.session }?.invalidateAndCancel() }

    func receive(_ input: Request, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> Receipt {
        let id = UUID()
        defer { _ = state.withLock { $0.cancelled.remove(id) } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var request = URLRequest(url: input.url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if let range = input.range {
                    request.setValue("bytes=\(range.lower)-\(range.upper)", forHTTPHeaderField: "Range")
                    if let validator = input.representation?.validator {
                        request.setValue(validator.value, forHTTPHeaderField: "If-Range")
                    }
                }
                let preparedRequest = request
                let task: URLSessionDataTask? = state.withLock { state in
                    guard state.cancelled.remove(id) == nil, let session = state.session else { return nil }
                    let task = session.dataTask(with: preparedRequest)
                    state.contexts[task.taskIdentifier] = Context(id: id, request: input, task: task, continuation: continuation, progress: progress)
                    return task
                }
                if let task { task.resume() }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.cancel(id) }
    }

    private func cancel(_ id: UUID) {
        let task: URLSessionDataTask? = state.withLock { state in
            guard let key = state.contexts.first(where: { $0.value.id == id })?.key else {
                state.cancelled.insert(id)
                return nil
            }
            state.contexts[key]?.error = CancellationError()
            return state.contexts[key]?.task
        }
        task?.cancel()
    }

    private static func validate(_ response: HTTPURLResponse, for request: Request) throws -> Int64 {
        if let range = request.range {
            if response.statusCode == 200 {
                throw DownloadTransferFailure.restart("服务器无法从已下载的位置继续。确认后将从头重新下载。", singleStream: true)
            }
            if response.statusCode == 416 { throw DownloadTransferFailure.restart("服务器上的文件范围已变化，需要重新下载。") }
            guard response.statusCode == 206 else { throw DownloadTransferFailure.interrupted("下载服务器返回错误（\(response.statusCode)），已保留进度。") }
            guard let interval = DownloadCheckpoint.contentRange(response.value(forHTTPHeaderField: "Content-Range")),
                  interval.lower == range.lower, interval.upper == range.upper else {
                throw DownloadTransferFailure.restart("服务器返回的文件部分不匹配。确认后将改用单路重新下载。", singleStream: true)
            }
            if let expected = request.representation {
                guard interval.total == expected.length, expected.matches(response) else {
                    throw DownloadTransferFailure.restart("服务器上的文件已变化，不能与之前的数据合并。请确认重新下载。")
                }
            }
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
                throw DownloadTransferFailure.restart("服务器无法提供可直接续传的文件。确认后将改用单路重新下载。", singleStream: true)
            }
            return range.length
        }
        guard response.statusCode == 200 else { throw DownloadTransferFailure.interrupted("下载服务器返回错误（\(response.statusCode)），已保留进度。") }
        return response.expectedContentLength
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let allowed = state.withLock { state -> Bool in
            guard var context = state.contexts[dataTask.taskIdentifier], context.error == nil else { return false }
            do {
                guard let http = response as? HTTPURLResponse else { throw DownloadTransferFailure.interrupted() }
                context.expected = try Self.validate(http, for: context.request)
                context.response = http
                if let destination = context.request.destination {
                    let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    guard values?.isSymbolicLink != true, Int64(values?.fileSize ?? 0) == context.request.existingBytes else {
                        throw DownloadTransferFailure.restart("本地下载进度已变化，需要重新下载。")
                    }
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                            throw DownloadTransferFailure.interrupted("无法保存下载文件，请检查剩余空间。")
                        }
                    }
                    let handle = try FileHandle(forWritingTo: destination)
                    try handle.seekToEnd()
                    context.handle = handle
                }
                state.contexts[dataTask.taskIdentifier] = context
                return true
            } catch {
                context.error = error
                state.contexts[dataTask.taskIdentifier] = context
                return false
            }
        }
        return allowed ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let event = state.withLock { state -> ((@Sendable (Int64, Int64) -> Void), Int64, Int64, Bool)? in
            guard var context = state.contexts[dataTask.taskIdentifier], context.error == nil else { return nil }
            do {
                let count = Int64(data.count)
                guard count <= Int64.max - context.received,
                      context.expected < 0 || context.received + count <= context.expected else {
                    throw DownloadTransferFailure.restart("服务器返回的文件长度不匹配，需要重新下载。")
                }
                try context.handle?.write(contentsOf: data)
                context.received += count
                state.contexts[dataTask.taskIdentifier] = context
                return (context.progress, context.request.existingBytes + context.received, context.expected, false)
            } catch {
                context.error = error
                state.contexts[dataTask.taskIdentifier] = context
                return (context.progress, 0, 0, true)
            }
        }
        if let event {
            if event.3 { dataTask.cancel() } else { event.0(event.1, event.2) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = state.withLock({ $0.contexts.removeValue(forKey: task.taskIdentifier) }) else { return }
        do {
            defer { try? context.handle?.close() }
            try context.handle?.synchronize()
            if let failure = context.error ?? error { throw failure }
            guard let response = context.response, context.expected < 0 || context.received == context.expected else {
                throw DownloadTransferFailure.interrupted("文件未下载完整，已保留已下载部分。")
            }
            context.continuation.resume(returning: Receipt(response: response, receivedBytes: context.received))
        } catch {
            context.continuation.resume(throwing: error)
        }
    }
}
