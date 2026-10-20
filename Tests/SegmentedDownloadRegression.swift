import Foundation
import CryptoKit

@main
struct SegmentedDownloadRegression {
    static func check(_ value: Bool, _ message: String = "Check failed") { precondition(value, message) }
    struct Fixture: Decodable { let bytes: Int64; let sha256: String; let changedSHA256: String }
    struct Stats: Decodable {
        struct Request: Decodable { let path: String; let range: String?; let ifRange: String? }
        let requests: [Request]
        let capMaximum: Int
    }

    static func json<T: Decodable>(_ path: String, base: URL) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: URL(string: path, relativeTo: base)!.absoluteURL)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func fresh(_ path: String, base: URL, store: DownloadTransferStore, transport: HTTPRangeTransfer,
                      limiter: DownloadTransferLimiter) throws -> SegmentedDownloadEngine {
        let record = DownloadCheckpoint(id: UUID(), url: URL(string: path, relativeTo: base)!.absoluteURL,
                                        context: Data("source-and-target-context".utf8), fileName: "Test.ipa")
        try store.save(record)
        return SegmentedDownloadEngine(record: record, store: store, transport: transport, limiter: limiter)
    }

    static func pause(_ engine: SegmentedDownloadEngine) async throws -> [Int: Int64] {
        let task = Task { try await engine.run { _ in } }
        let deadline = Date().addingTimeInterval(10)
        while try await engine.savedProgress().bytes < 262144 {
            try await Task.sleep(for: .milliseconds(10))
            check(Date() < deadline, "No initial bytes")
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation unexpectedly completed the file") }
        catch is CancellationError { }
        let record = await engine.checkpoint()
        check(record.phase == .paused)
        let store = try DownloadTransferStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
        return try Dictionary(uniqueKeysWithValues: record.parts().map { ($0.index, try store.size(store.part(record.id, $0.index))) })
    }

    static func expectsRestart(_ engine: SegmentedDownloadEngine) async throws {
        do { _ = try await engine.run { _ in }; preconditionFailure("Unsafe download was accepted") }
        catch let error as DownloadTransferFailure { check(error.requiresRestart) }
        check(await engine.checkpoint().phase == .requiresRestart)
    }

    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let store = try DownloadTransferStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
        let transport = HTTPRangeTransfer(), limiter = DownloadTransferLimiter()
        defer { transport.invalidate() }
        let fixture: Fixture = try await json("/fixture.json", base: base)
        var cases: [String] = []

        var plan = DownloadCheckpoint(id: UUID(), url: base, context: Data(), fileName: "x")
        plan.representation = .init(length: 11, validator: .etag("\"x\"")); plan.partCount = 4
        let parts = plan.parts()
        check(parts.map(\.length) == [3, 3, 3, 2])
        check(parts.first?.lower == 0 && parts.last?.upper == 10)
        check(DownloadCheckpoint.contentRange("bytes 2-1/10") == nil)
        check(DownloadCheckpoint.contentRange("bytes 0-10/10") == nil)
        cases.append("part coverage and strict Content-Range")

        func validator(_ fields: [String: String]) -> DownloadCheckpoint.Validator? {
            DownloadCheckpoint.Representation.validator(for: HTTPURLResponse(url: base, statusCode: 206, httpVersion: nil, headerFields: fields)!)
        }
        check(validator(["ETag": "\"strong\""]) == .etag("\"strong\""))
        check(validator(["ETag": "W/\"weak\""]) == nil)
        let modified = "Tue, 20 Oct 2026 00:00:00 GMT"
        check(validator(["Last-Modified": modified, "Date": "Tue, 20 Oct 2026 00:01:00 GMT"]) == .lastModified(modified))
        check(validator(["Last-Modified": modified, "Date": "Tue, 20 Oct 2026 00:00:59 GMT"]) == nil)
        check(validator(["ETag": "W/\"weak\"", "Last-Modified": modified, "Date": "Tue, 20 Oct 2026 00:01:00 GMT"]) == nil)
        cases.append("strong ETag and HTTP-date validators reject weak or ambiguous identities")

        let serial = DownloadTransferLimiter(limit: 1)
        let holder = Task { try await serial.withPermit { try await Task.sleep(for: .milliseconds(200)) } }
        try await Task.sleep(for: .milliseconds(30))
        let queued = Task { try await serial.withPermit { try await Task.sleep(for: .seconds(10)) } }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        do { try await queued.value; preconditionFailure("Queued cancellation was ignored") } catch is CancellationError { }
        try await holder.value
        let next = try await serial.withPermit { 42 }
        check(next == 42)
        cases.append("cancelling a queued transfer preserves permits for following downloads")

        let engine = try fresh("/range.ipa", base: base, store: store, transport: transport, limiter: limiter)
        let initial = try await pause(engine)
        let checkpoint = await engine.checkpoint()
        check(initial.values.reduce(0,+) > 0 && initial.values.reduce(0,+) < fixture.bytes)
        let loaded = store.load().records.first { $0.id == checkpoint.id }!
        check(loaded.context == checkpoint.context)
        let restored = SegmentedDownloadEngine(record: loaded, store: store, transport: transport, limiter: limiter)
        let result = try await restored.run { _ in }
        check(result.bytes == fixture.bytes && result.sha256 == fixture.sha256)
        let stats: Stats = try await json("/stats", base: base)
        for part in checkpoint.parts() {
                let saved = initial[part.index] ?? 0
                if saved == part.length { continue }
                check(stats.requests.filter { $0.path == "/range.ipa" }.contains { request in
                    request.range == "bytes=\(part.lower + saved)-\(part.upper)" && request.ifRange == checkpoint.representation?.validator?.value
                }, "A resumed part did not start at its saved byte offset")
        }
        cases.append("pause, disk restore, exact Range continuation and SHA-256")

        let ready = SegmentedDownloadEngine(record: await restored.checkpoint(), store: store, transport: transport, limiter: limiter)
        let beforeReady = stats.requests.count
        let localResult = try await ready.run { _ in }
        check(localResult.sha256 == fixture.sha256)
        let afterReady: Stats = try await json("/stats", base: base)
        check(afterReady.requests.count == beforeReady)
        cases.append("completed file recovery without network")

        let retry = try fresh("/disconnect.ipa", base: base, store: store, transport: transport, limiter: limiter)
        do { _ = try await retry.run { _ in }; preconditionFailure("Broken response accepted") } catch { }
        let failed = await retry.checkpoint()
        check(failed.phase == .failed)
        check(try await retry.savedProgress().bytes > 0)
        let _: [String: Bool] = try await json("/control?operation=heal", base: base)
        let recovered = try await retry.run { _ in }
        check(recovered.sha256 == fixture.sha256)
        cases.append("connection failure retains bytes and retries from the missing interval")

        let mutable = try fresh("/mutable.ipa", base: base, store: store, transport: transport, limiter: limiter)
        let oldOffsets = try await pause(mutable)
        let old = await mutable.checkpoint()
        let _: [String: Bool] = try await json("/control?operation=mutate", base: base)
        try await expectsRestart(mutable)
        for part in old.parts() { check(try store.size(store.part(old.id, part.index)) == oldOffsets[part.index]) }
        try await mutable.restartAfterConfirmation()
        let changed = try await mutable.run { _ in }
        check(changed.sha256 == fixture.changedSHA256)
        cases.append("changed files preserve old bytes until explicit restart")

        for path in ["/ignore.ipa", "/no-validator.ipa"] {
            let incompatible = try fresh(path, base: base, store: store, transport: transport, limiter: limiter)
            try await expectsRestart(incompatible)
            let old = await incompatible.checkpoint()
            check(old.restartInSingleMode)
            check(try store.size(store.part(old.id, 0)) == 0)
            let before: Stats = try await json("/stats", base: base)
            try await expectsRestart(incompatible)
            let after: Stats = try await json("/stats", base: base)
            check(before.requests.count == after.requests.count)
            try await incompatible.restartAfterConfirmation()
            let single = try await incompatible.run { _ in }
            check(single.sha256 == fixture.sha256)
        }
        cases.append("unsupported Range or absent validators require consent before single-stream restart")

        for path in ["/racy.ipa", "/wrong-range.ipa", "/wrong-total.ipa"] {
            let invalid = try fresh(path, base: base, store: store, transport: transport, limiter: limiter)
            try await expectsRestart(invalid)
            check(try await invalid.savedProgress().bytes == 0)
        }
        cases.append("inconsistent validators, intervals and totals rejected before writing")

        let forbidden = try fresh("/forbidden.ipa", base: base, store: store, transport: transport, limiter: limiter)
        do { _ = try await forbidden.run { _ in }; preconditionFailure("HTTP error body accepted") } catch { }
        check(await forbidden.checkpoint().phase == .failed)
        cases.append("HTTP errors never imported")

        let first = try fresh("/cap-one.ipa", base: base, store: store, transport: transport, limiter: limiter)
        let second = try fresh("/cap-two.ipa", base: base, store: store, transport: transport, limiter: limiter)
        async let one = first.run { _ in }
        async let two = second.run { _ in }
        let (oneResult, twoResult) = try await (one, two)
        check(oneResult.sha256 == fixture.sha256 && twoResult.sha256 == fixture.sha256)
        let cap: Stats = try await json("/stats", base: base)
        check((2...4).contains(cap.capMaximum), "Transfers did not obey the shared four-connection limit: \(cap.capMaximum)")
        cases.append("real parallel transfer with a shared four-request limit")

        try store.markDiscarded(checkpoint.id)
        let restoredRecords = store.load()
        check(!restoredRecords.records.contains { $0.id == checkpoint.id })
        check(!FileManager.default.fileExists(atPath: store.directory(checkpoint.id).path))
        cases.append("cancel tombstones survive process restarts")

        let corruptID = UUID()
        try FileManager.default.createDirectory(at: store.directory(corruptID), withIntermediateDirectories: true)
        try Data("corrupt-checkpoint".utf8).write(to: store.manifest(corruptID))
        let corrupted = store.load()
        check(!corrupted.issues.isEmpty && FileManager.default.fileExists(atPath: store.manifest(corruptID).path))
        cases.append("corrupt records preserved without unsafe recovery")
        print("SegmentedDownloadRegression passed: \(cases.count) cases")
        for name in cases { print("PASS: \(name)") }
    }
}
