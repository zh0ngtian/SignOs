import Foundation
import CryptoKit
import os

actor SegmentedDownloadEngine {
    struct Progress: Sendable {
        let bytes: Int64
        let total: Int64
        var assembling = false
    }
    struct Result: Sendable {
        let file: URL
        let sha256: String
        let bytes: Int64
    }
    private struct ProgressState: Sendable {
        var offsets: [Int: Int64]
        var total: Int64
    }

    private var record: DownloadCheckpoint
    private let store: DownloadTransferStore
    private let transport: HTTPRangeTransfer
    private let limiter: DownloadTransferLimiter
    private let minimumPartSize: Int64
    private var running = false

    init(record: DownloadCheckpoint, store: DownloadTransferStore, transport: HTTPRangeTransfer,
         limiter: DownloadTransferLimiter, minimumPartSize: Int64 = 1_048_576) {
        self.record = record
        self.store = store
        self.transport = transport
        self.limiter = limiter
        self.minimumPartSize = max(1, minimumPartSize)
    }

    func checkpoint() -> DownloadCheckpoint { record }

    func savedProgress() throws -> Progress {
        let bytes = try (0..<record.partCount).reduce(Int64(0)) { sum, index in sum + (try store.size(store.part(record.id, index))) }
        return Progress(bytes: bytes, total: record.representation?.length ?? 0)
    }

    func restartAfterConfirmation() throws {
        guard !running else { throw DownloadTransferFailure.interrupted("请等待当前下载暂停后再试。") }
        try store.resetParts(record)
        record.mode = record.restartInSingleMode ? .single : .segmented
        record.representation = nil
        record.completedSHA256 = nil
        record.phase = .paused
        record.message = nil
        record.partCount = 1
        try store.save(record)
    }

    func run(progress: @escaping @Sendable (Progress) async -> Void) async throws -> Result {
        guard !running else { throw DownloadTransferFailure.interrupted("此下载已在进行中。") }
        guard !store.discarded(record.id) else { throw CancellationError() }
        running = true
        defer { running = false }
        do {
            try Task.checkCancellation()
            if record.phase == .requiresRestart {
                throw DownloadTransferFailure.restart(record.message ?? "此下载需要重新开始。", singleStream: record.restartInSingleMode)
            }
            if record.phase == .ready, let digest = record.completedSHA256 {
                let file = store.assembled(record.id)
                let verified = try await Self.hash(file)
                guard verified.sha256 == digest, verified.bytes == record.representation?.length else {
                    throw DownloadTransferFailure.restart("本地下载文件已变化，需要重新下载。")
                }
                return verified
            }
            record.phase = .partial
            record.message = nil
            try store.save(record)

            if record.mode == .segmented { try await prepareRepresentation() }
            else if try store.size(store.part(record.id, 0)) > 0 {
                throw DownloadTransferFailure.restart("此服务器不支持续传，继续需要从头重新下载。", singleStream: true)
            }

            let initial = try offsets()
            let aggregate = OSAllocatedUnfairLock(initialState: ProgressState(offsets: initial, total: record.representation?.length ?? 0))
            let (stream, continuation) = AsyncStream<Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            async let reporting: Void = Self.report(stream, to: progress)
            await progress(Progress(bytes: initial.values.reduce(0, +), total: record.representation?.length ?? 0))
            do {
                let checkpoint = record, store = store, transport = transport, limiter = limiter
                if record.mode == .single {
                    let result = try await limiter.withPermit {
                        try await transport.receive(HTTPRangeTransfer.Request(url: checkpoint.url, destination: store.part(checkpoint.id, 0))) { bytes, total in
                            continuation.yield(Progress(bytes: bytes, total: max(0, total)))
                        }
                    }
                    record.representation = .init(length: result.receivedBytes, validator: nil)
                } else {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for part in checkpoint.parts() {
                            let existing = initial[part.index] ?? 0
                            if existing == part.length { continue }
                            group.addTask {
                                try await limiter.withPermit {
                                    try Task.checkCancellation()
                                    let request = HTTPRangeTransfer.Request(url: checkpoint.url,
                                        destination: store.part(checkpoint.id, part.index), existingBytes: existing,
                                        range: .init(index: part.index, lower: part.lower + existing, upper: part.upper), representation: checkpoint.representation)
                                    _ = try await transport.receive(request) { bytes, _ in
                                        let update = aggregate.withLock { state -> Progress in
                                            state.offsets[part.index] = bytes
                                            return Progress(bytes: state.offsets.values.reduce(0, +), total: state.total)
                                        }
                                        continuation.yield(update)
                                    }
                                }
                            }
                        }
                        for try await _ in group { }
                    }
                }
                continuation.finish()
                await reporting
            } catch {
                continuation.finish()
                await reporting
                throw error
            }

            try Task.checkCancellation()
            let total = record.representation?.length ?? 0
            await progress(Progress(bytes: total, total: total, assembling: true))
            let result = try await Self.assemble(record, store: store)
            try Task.checkCancellation()
            record.phase = .ready
            record.completedSHA256 = result.sha256
            try store.save(record)
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                record.phase = .paused
                record.message = nil
                try store.save(record)
                throw CancellationError()
            }
            if let reason = error as? DownloadTransferFailure, reason.requiresRestart {
                record.phase = .requiresRestart
                record.restartInSingleMode = reason.singleStream
                record.message = reason.message
            } else {
                record.phase = .failed
                record.message = (error as? DownloadTransferFailure)?.message ?? "下载中断，已保留进度，可点击继续。"
            }
            try store.save(record)
            throw error
        }
    }

    private func prepareRepresentation() async throws {
        let url = record.url, transport = transport
        let receipt = try await limiter.withPermit {
            try await transport.receive(.init(url: url, range: .init(index: 0, lower: 0, upper: 0), probe: true))
        }
        guard let range = DownloadCheckpoint.contentRange(receipt.response.value(forHTTPHeaderField: "Content-Range")),
              let validator = DownloadCheckpoint.Representation.validator(for: receipt.response) else {
            throw DownloadTransferFailure.restart("服务器无法确认文件是否变化。确认后将改用单路重新下载。", singleStream: true)
        }
        let representation = DownloadCheckpoint.Representation(length: range.total, validator: validator)
        if let previous = record.representation {
            guard previous == representation else { throw DownloadTransferFailure.restart("服务器上的文件已变化，不能接续旧文件。请确认重新下载。") }
        } else {
            record.representation = representation
            record.partCount = Int(min(4, max(1, range.total / minimumPartSize)))
        }
        _ = try offsets()
        try store.save(record)
    }

    private func offsets() throws -> [Int: Int64] {
        if record.mode == .single { return [0: try store.size(store.part(record.id, 0))] }
        var result: [Int: Int64] = [:]
        for part in record.parts() {
            let size = try store.size(store.part(record.id, part.index))
            guard size <= part.length else { throw DownloadTransferFailure.restart("本地下载进度不一致，需要重新下载。") }
            result[part.index] = size
        }
        return result
    }

    private static func report(_ stream: AsyncStream<Progress>, to receiver: @escaping @Sendable (Progress) async -> Void) async {
        for await value in stream {
            await receiver(value)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    @concurrent private static func hash(_ url: URL) async throws -> Result {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256(), bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
            bytes += Int64(data.count)
        }
        return Result(file: url, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }

    @concurrent private static func assemble(_ record: DownloadCheckpoint, store: DownloadTransferStore) async throws -> Result {
        let scratch = store.directory(record.id).appendingPathComponent("assembling.ipa")
        if FileManager.default.fileExists(atPath: scratch.path) { try FileManager.default.removeItem(at: scratch) }
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil) else {
            throw DownloadTransferFailure.interrupted("无法整理下载文件，请检查剩余空间。")
        }
        let output = try FileHandle(forWritingTo: scratch)
        defer { try? output.close() }
        var digest = SHA256(), bytes: Int64 = 0
        for index in 0..<record.partCount {
            let input = try FileHandle(forReadingFrom: store.part(record.id, index))
            defer { try? input.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
                digest.update(data: data)
                bytes += Int64(data.count)
            }
        }
        guard bytes > 0, bytes == record.representation?.length else {
            throw DownloadTransferFailure.restart("本地下载文件未完整保存，需要重新下载。")
        }
        try output.synchronize()
        try output.close()
        let destination = store.assembled(record.id)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: scratch, to: destination)
        return Result(file: destination, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }
}
