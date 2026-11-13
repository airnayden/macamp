import Foundation
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

/// Serialized because several assertions are timing-driven (latency-controlled fake);
/// each test builds its own service + separator + temp files, so there is no shared state.
///
/// The queue-feed API (`updateQueue(current:upcoming:)`) and its priority window are
/// GONE — `KaraokeRenderService` is driven only by explicit `requestRender(_:)` calls.
@MainActor
@Suite(.serialized)
struct KaraokeRenderServiceTests {
    static let modelSHA = "karaoke-render-test-model-sha"

    @Test("requests run serially, one at a time, in FIFO order")
    func requestsRunSeriallyInFIFOOrder() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let separator = FakeStemSeparator(latency: .milliseconds(25))
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        service.requestRender(files[2])
        await Self.waitUntil { separator.separateCallCount == 3 }

        #expect(separator.requestedURLs == files)
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("a rendered request reports success through onFinished")
    func renderedRequestReportsSuccess() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { !collector.finished.isEmpty }

        #expect(separator.separateCallCount == 1)
        #expect(collector.finished == [FinishedEvent(url: files[0], result: .rendered)])
    }

    @Test("an already-cached url performs no separation and reports success")
    func cachedURLReportsSuccessWithoutSeparation() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let cachedKey = try SeparationCacheKey(url: files[0], modelSHA: Self.modelSHA)
        let cachedInstrumental = files[0].deletingLastPathComponent().appendingPathComponent("cached.m4a")
        let cache = FakeInstrumentalCache(seeded: [cachedKey: cachedInstrumental])
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(separator: separator, cache: cache, modelSHA: Self.modelSHA)
        service.onFinished = { collector.record(finished: $0, result: $1) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { !collector.finished.isEmpty }

        #expect(separator.separateCallCount == 0)
        #expect(collector.finished == [FinishedEvent(url: files[0], result: .alreadyCached)])
    }

    @Test("disabling cancels in-flight work and clears pending requests")
    func disableCancelsInFlightAndClearsPending() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let separator = FakeStemSeparator(latency: .milliseconds(300))
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        service.requestRender(files[2])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.setEnabled(false)
        try await Task.sleep(for: .milliseconds(500))

        #expect(separator.requestedURLs == [files[0]])
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("diskFull stops rendering and surfaces exactly one notice")
    func diskFullSurfacesExactlyOneNotice() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let separator = FakeStemSeparator(failingWith: .diskFull, latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onNotice = { collector.record(notice: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        service.requestRender(files[2])
        await Self.waitUntil { !collector.notices.isEmpty }
        try await Task.sleep(for: .milliseconds(120))

        #expect(collector.notices == [.diskFull])
        #expect(separator.separateCallCount == 1)
    }

    @Test("a duplicate request for an in-flight url is dropped")
    func duplicateRequestForInFlightURLIsDropped() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { separator.separateCallCount == 1 }
        // files[0] is now in flight — re-requesting it must be dropped.
        service.requestRender(files[0])
        try await Task.sleep(for: .milliseconds(300))

        #expect(separator.requestedURLs == [files[0]])
        #expect(separator.separateCallCount == 1)
    }

    @Test("progress values are strictly monotone and non-repeating per track")
    func progressStrictlyMonotonePerTrack() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onProgress = { collector.record(progress: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        await Self.waitUntil { collector.progress.count(where: { $0.fraction >= 1.0 }) == 2 }

        for file in files {
            let fractions = collector.progress.filter { $0.url == file }.map(\.fraction)
            #expect(!fractions.isEmpty)
            #expect(Self.isStrictlyIncreasing(fractions))
        }
    }

    @Test("the queue seam fires the exact snapshot on request, start, and finish")
    func queueSeamFiresExactSnapshots() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { !collector.finished.isEmpty }

        #expect(collector.snapshots == [
            KaraokeQueueSnapshot(currentURL: nil, pendingURLs: [files[0]], isPaused: false),
            KaraokeQueueSnapshot(currentURL: files[0], pendingURLs: [], isPaused: false),
            KaraokeQueueSnapshot(currentURL: nil, pendingURLs: [], isPaused: false),
        ])
    }

    @Test("removePending drops a pending item; removing the in-flight item is a no-op")
    func removePendingDropsPendingButNotInFlight() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        service.requestRender(files[2])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.removePending(files[2])
        service.removePending(files[0])
        await Self.waitUntil { separator.separateCallCount == 2 }
        try await Task.sleep(for: .milliseconds(120))

        #expect(separator.requestedURLs == [files[0], files[1]])
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("movePending reorders the driver's actual pick order")
    func movePendingReordersPickOrder() async throws {
        let files = try Self.makeTempFiles(count: 3)
        // A one-second first render parks the driver on files[0] with room to spare
        // while its successors clear preflight; latency drops once the reorder lands.
        let separator = FakeStemSeparator(latency: .seconds(1))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        service.requestRender(files[2])
        // `separateCallCount == 1` proves only that files[0] started — its successors
        // may still be in preflight, and `movePending` on a URL that has not yet
        // reached `pending` is a silent no-op (the historical flake: the queue then
        // ran in request order). Fence on the queue snapshot instead: it is published
        // only once files[0] is in flight AND both successors are pending.
        await Self.waitUntil {
            collector.snapshots.contains(
                KaraokeQueueSnapshot(
                    currentURL: files[0],
                    pendingURLs: [files[1], files[2]],
                    isPaused: false
                )
            )
        }
        service.movePending(files[2], to: 0)
        separator.setLatency(.milliseconds(15))
        await Self.waitUntil(timeout: .seconds(5)) { separator.separateCallCount == 3 }

        #expect(separator.requestedURLs == [files[0], files[2], files[1]])
        #expect(separator.maxObservedConcurrency == 1)
        #expect(collector.snapshots.contains(
            KaraokeQueueSnapshot(
                currentURL: files[0],
                pendingURLs: [files[2], files[1]],
                isPaused: false
            )
        ))
    }

    @Test("a second request is queued while the first is in flight (concurrency stays 1)")
    func secondRequestIsQueuedWhileFirstInFlight() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(120))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        await Self.waitUntil { separator.separateCallCount == 1 }

        await Self.waitUntil {
            collector.snapshots.contains(
                KaraokeQueueSnapshot(currentURL: files[0], pendingURLs: [files[1]], isPaused: false)
            )
        }
        #expect(separator.maxObservedConcurrency == 1)

        await Self.waitUntil { separator.separateCallCount == 2 }
        #expect(separator.maxObservedConcurrency == 1)
    }
}

// MARK: - Test helpers

extension KaraokeRenderServiceTests {
    static func makeTempFiles(count: Int) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("karaoke-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0 ..< count).map { index in
            let url = directory.appendingPathComponent("track-\(index).flac")
            try Data([0x00, 0x01, 0x02, UInt8(index)]).write(to: url)
            return url
        }
    }

    static func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func isStrictlyIncreasing(_ values: [Double]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }
}

/// A completed-render event recorded from the `@Sendable` `onFinished` callback.
struct FinishedEvent: Equatable {
    let url: URL
    let result: KaraokeRenderResult
}

/// A lock-guarded sink so the `@Sendable` `onProgress` / `onNotice` / `onFinished`
/// callbacks can record events from any isolation (they fire on the main actor, but
/// the closures are `@Sendable`).
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var progressEvents: [KaraokePrewarmProgress] = []
    private var noticeEvents: [KaraokePrewarmNotice] = []
    private var finishedEvents: [FinishedEvent] = []
    private var snapshotEvents: [KaraokeQueueSnapshot] = []

    func record(progress event: KaraokePrewarmProgress) {
        lock.withLock { progressEvents.append(event) }
    }

    func record(notice event: KaraokePrewarmNotice) {
        lock.withLock { noticeEvents.append(event) }
    }

    func record(finished url: URL, result: KaraokeRenderResult) {
        lock.withLock { finishedEvents.append(FinishedEvent(url: url, result: result)) }
    }

    func record(snapshot event: KaraokeQueueSnapshot) {
        lock.withLock { snapshotEvents.append(event) }
    }

    var progress: [KaraokePrewarmProgress] {
        lock.withLock { progressEvents }
    }

    var notices: [KaraokePrewarmNotice] {
        lock.withLock { noticeEvents }
    }

    var finished: [FinishedEvent] {
        lock.withLock { finishedEvents }
    }

    var snapshots: [KaraokeQueueSnapshot] {
        lock.withLock { snapshotEvents }
    }
}
