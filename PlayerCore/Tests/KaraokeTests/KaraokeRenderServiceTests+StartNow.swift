import Foundation
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

/// `startNow(_:)` / `stopCurrent()` coverage, split to keep the shared suite within its file-length budget.
/// Reuses that file's `Collector` / `FinishedEvent` / `makeTempFiles` / `waitUntil`.
extension KaraokeRenderServiceTests {
    @Test("startNow preempts the in-flight item, requeues it at the front, and runs the target next")
    func startNowPreemptsAndRequeuesInFlightAtFront() async throws {
        let files = try Self.makeTempFiles(count: 4)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
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
        service.requestRender(files[3])
        await Self.waitUntil { separator.separateCallCount == 1 }
        // files[0] is in flight, pending == [files[1], files[2], files[3]].
        service.startNow(files[1])
        await Self.waitUntil { separator.separateCallCount == 5 }

        #expect(separator.requestedURLs == [files[0], files[1], files[0], files[2], files[3]])
        #expect(separator.maxObservedConcurrency == 1)
        #expect(collector.snapshots.contains(
            KaraokeQueueSnapshot(
                currentURL: files[1],
                pendingURLs: [files[0], files[2], files[3]],
                isPaused: false
            )
        ))
    }

    @Test("startNow auto-resumes a paused driver")
    func startNowAutoResumesWhenPaused() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
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
        service.requestRender(files[1])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.pause()
        await Self.waitUntil {
            collector.snapshots.contains(
                KaraokeQueueSnapshot(currentURL: nil, pendingURLs: files, isPaused: true)
            )
        }
        #expect(separator.separateCallCount == 1)

        service.startNow(files[1])
        await Self.waitUntil { separator.separateCallCount == 3 }

        #expect(separator.requestedURLs == [files[0], files[1], files[0]])
        #expect(collector.snapshots.contains(
            KaraokeQueueSnapshot(currentURL: files[1], pendingURLs: [files[0]], isPaused: false)
        ))
    }

    @Test("startNow on the in-flight item is a no-op")
    func startNowOnInFlightItemIsNoOp() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        await Self.waitUntil { separator.separateCallCount == 1 }
        // Starting the already-in-flight item must not cancel or restart it.
        service.startNow(files[0])
        await Self.waitUntil { separator.separateCallCount == 2 }

        #expect(separator.requestedURLs == [files[0], files[1]])
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("startNow enqueues and starts a URL that was never requested")
    func startNowEnqueuesAndStartsUnqueuedURL() async throws {
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
        // files[0] was never requestRender'd — startNow must enqueue and run it.
        service.startNow(files[0])
        await Self.waitUntil { !collector.finished.isEmpty }

        #expect(separator.requestedURLs == [files[0]])
        #expect(collector.finished == [FinishedEvent(url: files[0], result: .rendered)])
    }

    @Test("startNow preempts while its target is actively preflighting without duplicating it")
    func startNowPreemptsTargetDuringActivePreflightWithoutDuplication() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let targetKey = try SeparationCacheKey(url: files[1], modelSHA: Self.modelSHA)
        let cache = BlockingLookupCache(blockedKey: targetKey)
        let separator = FakeStemSeparator(latency: .seconds(1))
        let collector = Collector()
        let service = KaraokeRenderService(separator: separator, cache: cache, modelSHA: Self.modelSHA)
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.requestRender(files[1])
        service.requestRender(files[2])
        await Self.waitUntilAsync { await cache.isBlocked }

        let snapshotCountBeforeStartNow = collector.snapshots.count
        service.startNow(files[1])
        await Self.waitUntil {
            let snapshots = collector.snapshots
            return snapshots.count > snapshotCountBeforeStartNow && snapshots.last ==
                KaraokeQueueSnapshot(currentURL: nil, pendingURLs: [files[0]], isPaused: false)
        }
        #expect(separator.requestedURLs == [files[0]])

        await cache.release()
        await Self.waitUntil(timeout: .seconds(5)) { collector.finished.count >= 3 }

        #expect(separator.requestedURLs == [files[0], files[1], files[0], files[2]])
        #expect(collector.snapshots.contains(
            KaraokeQueueSnapshot(currentURL: nil, pendingURLs: [files[1], files[0]], isPaused: false)
        ))
        #expect(collector.snapshots.allSatisfy { snapshot in
            snapshot.pendingURLs.count(where: { $0 == files[1] }) <= 1
        })
    }

    @Test("rapid startNow retarget does not expose or double-finish an active preflight")
    func rapidStartNowRetargetDoesNotLeakActivePreflight() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let blockedKey = try SeparationCacheKey(url: files[1], modelSHA: Self.modelSHA)
        let cache = BlockingLookupCache(blockedKey: blockedKey)
        let separator = FakeStemSeparator(latency: .seconds(1))
        let collector = Collector()
        let service = KaraokeRenderService(separator: separator, cache: cache, modelSHA: Self.modelSHA)
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.requestRender(files[2])
        await Self.waitUntil {
            collector.snapshots.contains(
                KaraokeQueueSnapshot(currentURL: files[0], pendingURLs: [files[2]], isPaused: false)
            )
        }
        service.requestRender(files[1])
        await Self.waitUntilAsync { await cache.isBlocked }

        service.startNow(files[1])
        service.startNow(files[2])
        await Self.waitUntil {
            collector.snapshots.contains(where: { $0.currentURL == files[2] })
        }

        #expect(collector.snapshots.allSatisfy { snapshot in
            snapshot.currentURL != files[1] && !snapshot.pendingURLs.contains(files[1])
        })

        await cache.release()
        await Self.waitUntil(timeout: .seconds(7)) {
            collector.finished.count >= 3 && collector.snapshots.last == KaraokeQueueSnapshot(
                currentURL: nil,
                pendingURLs: [],
                isPaused: false
            )
        }

        let blockedEvents = collector.finished.filter { $0.url == files[1] }
        #expect(blockedEvents == [FinishedEvent(url: files[1], result: .rendered)])
        #expect(separator.requestedURLs == [files[0], files[2], files[0], files[1]])
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("requestRender deduplicates a target owned only by startNow preemption")
    func requestRenderDeduplicatesPreemptTarget() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let targetKey = try SeparationCacheKey(url: files[1], modelSHA: Self.modelSHA)
        let cache = BlockingLookupCache(blockedKey: targetKey, blockedLookupNumber: 2)
        let separator = FakeStemSeparator(latency: .seconds(1))
        let collector = Collector()
        let service = KaraokeRenderService(separator: separator, cache: cache, modelSHA: Self.modelSHA)
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.requestRender(files[1])
        await Self.waitUntil {
            collector.snapshots.contains(
                KaraokeQueueSnapshot(currentURL: files[0], pendingURLs: [files[1]], isPaused: false)
            )
        }

        service.startNow(files[1])
        service.requestRender(files[1])
        await Self.waitUntil(timeout: .seconds(5)) {
            collector.finished.contains(FinishedEvent(url: files[1], result: .rendered))
        }

        await cache.release()
        await Self.waitUntil(timeout: .seconds(5)) {
            separator.separateCallCount >= 3 && collector.snapshots.last == KaraokeQueueSnapshot(
                currentURL: nil,
                pendingURLs: [],
                isPaused: false
            )
        }

        let targetEvents = collector.finished.filter { $0.url == files[1] }
        #expect(targetEvents == [FinishedEvent(url: files[1], result: .rendered)])
        #expect(separator.requestedURLs == [files[0], files[1], files[0]])
        #expect(separator.separateCallCount == 3)
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("stopCurrent cancels the in-flight item, requeues it at the front, and pauses")
    func stopCurrentCancelsRequeuesFrontAndPauses() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
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
        service.requestRender(files[1])
        service.requestRender(files[2])
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.stopCurrent()
        await Self.waitUntil {
            collector.snapshots.contains(
                KaraokeQueueSnapshot(currentURL: nil, pendingURLs: files, isPaused: true)
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        // Held: nothing new ran, and the stopped item did NOT report completion.
        #expect(separator.separateCallCount == 1)
        #expect(collector.finished.isEmpty)

        service.resume()
        await Self.waitUntil { separator.separateCallCount == 2 }
        // The stopped files[0] resumes first, from the front of the queue.
        #expect(separator.requestedURLs == [files[0], files[0]])
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("a failed (non-diskFull) render still lets the driver continue to the next item")
    func failedRenderContinuesToNextItem() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        separator.setError(.inferenceFailed, for: files[0])
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onNotice = { collector.record(notice: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        await Self.waitUntil { collector.finished.count == 2 }

        #expect(collector.finished.contains(FinishedEvent(url: files[0], result: .failed)))
        #expect(collector.finished.contains(FinishedEvent(url: files[1], result: .rendered)))
        #expect(separator.requestedURLs == [files[0], files[1]])
        #expect(separator.separateCallCount == 2)
        #expect(collector.notices.isEmpty)
    }
}

private extension KaraokeRenderServiceTests {
    static func waitUntilAsync(
        timeout: Duration = .seconds(3),
        _ condition: @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
