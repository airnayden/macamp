// `DownloadQueueService` transport and failure paths: pause/resume, the two cancels,
// reordering, and every way a row can end badly without taking the queue with it.
//
// The mid-download interruptions are DETERMINISTIC, not timed: `interruptOnFirstDownloadTick`
// runs on the `onItemProgress` seam, and the driver AWAITS each publish before reading the
// next engine line — so a `pause()`/`cancel*()` raised there is guaranteed to have landed
// before the script's next line is consumed.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("Download queue transport")
struct DownloadQueueTransportTests {
    /// Pause is a REFILL-STOP: the row already transferring keeps transferring and
    /// finishes normally, and the row queued behind it simply never starts.
    ///
    /// The spawn count is the load-bearing half. Two spawns are the in-flight row's own
    /// prefetch and transfer; a third would mean the pending row was picked up anyway.
    @Test("pause mid-download lets the in-flight row finish while pending holds")
    func pauseLetsTheInFlightRowFinishAndHoldsPending() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        harness.interruptOnFirstDownloadTick { $0.pause() }
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForPausedIdle()

        let enqueuedIDs = try #require(harness.recorder.snapshots.first).pendingItems.map(\.id)
        let snapshot = harness.recorder.latestSnapshot
        #expect(snapshot.isPaused)
        #expect(snapshot.activeItems.isEmpty)
        // Only the row BEHIND the paused one is still pending: the in-flight row was
        // neither cancelled nor requeued, it completed.
        #expect(snapshot.pendingItems.map(\.id) == [enqueuedIDs[1]])
        #expect(harness.recorder.finished.map(\.item.id) == [enqueuedIDs[0]])
        #expect(harness.recorder.states(of: enqueuedIDs[0]).last == .finished(
            fileURL: URL(fileURLWithPath: DownloadFixture.finishedPath)
        ))
        #expect(harness.runner.spawnCount == 2)
    }

    /// Resume refills from `pending`. There is no requeued row to restart — the row that
    /// was in flight when pause landed has already finished — so what resume starts is
    /// the row that was held, from the top.
    @Test("resume refills from pending and the held row completes")
    func resumeRefillsFromPending() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
            DownloadFixture.infoScript(id: DownloadFixture.otherVideoID),
            DownloadFixture.happyDownloadScript,
        ])
        harness.interruptOnFirstDownloadTick { $0.pause() }
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForPausedIdle()
        let heldID = try #require(harness.recorder.latestSnapshot.pendingItems.first?.id)
        #expect(harness.recorder.finished.count == 1)

        harness.service.resume()
        await harness.waitForTerminals(2)

        #expect(harness.recorder.finished.map(\.item.id).last == heldID)
        #expect(harness.recorder.finished.count == 2)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    @Test("resume is idempotent and starting an empty queue is a no-op")
    func resumeIsIdempotent() {
        let harness = DownloadQueueHarness()

        harness.service.resume()
        harness.service.resume()

        #expect(harness.runner.spawnCount == 0)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// `cancelAll` must cut the child short even though the script would have succeeded —
    /// a finished-looking script that still lands `.cancelled` is the proof.
    @Test("cancelAll terminates the in-flight child and drops every pending row")
    func cancelAllTerminatesChildAndClearsPending() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        harness.interruptOnFirstDownloadTick { $0.cancelAll() }
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForTerminals(2)

        let enqueuedIDs = try #require(harness.recorder.snapshots.first).pendingItems.map(\.id)
        #expect(harness.recorder.states(of: enqueuedIDs[0]).last == .cancelled)
        #expect(harness.recorder.states(of: enqueuedIDs[1]).last == .cancelled)
        #expect(harness.recorder.finished.isEmpty)
        #expect(harness.recorder.latestSnapshot == .empty)
        // The pending row never reached its own prefetch.
        #expect(harness.runner.spawnCount == 2)
    }

    /// The ordering guarantee: samples produced for a row that has already left the queue
    /// are DROPPED. A cancelled row must not reappear as `downloading` or `finished`.
    @Test("progress arriving after a cancel never resurrects the row")
    func lateProgressNeverResurrectsACancelledRow() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
            DownloadFixture.infoScript(id: DownloadFixture.otherVideoID),
            DownloadFixture.happyDownloadScript,
        ])
        harness.interruptOnFirstDownloadTick { $0.cancelCurrent() }
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForTerminals(2)

        let enqueuedIDs = try #require(harness.recorder.snapshots.first).pendingItems.map(\.id)
        // The script had two more progress lines, a post-process line and a file line
        // after the tick that cancelled — none of them may appear.
        #expect(harness.recorder.states(of: enqueuedIDs[0]) == [
            .queued,
            .fetchingMetadata,
            .downloading(fraction: 0.25, speedBytesPerSec: 131_072, etaSeconds: 6),
            .cancelled,
        ])
        // Cancelling one row must not drain the queue.
        #expect(harness.recorder.states(of: enqueuedIDs[1]).last?.isTerminal == true)
        #expect(harness.recorder.finished.map(\.item.id) == [enqueuedIDs[1]])
    }

    @Test("cancelCurrent with nothing in flight is a no-op")
    func cancelCurrentWithNothingInFlightIsNoOp() {
        let harness = DownloadQueueHarness()

        harness.service.cancelCurrent()

        #expect(harness.recorder.snapshots.isEmpty)
    }

    /// One unwritable destination fails exactly ONE row. The sequenced probe is what makes
    /// that distinguishable from a queue that simply stopped.
    @Test("an unwritable destination fails only that row and the next one still runs")
    func unwritableDestinationFailsOneRowOnly() async throws {
        let harness = DownloadQueueHarness(
            scripts: [
                DownloadFixture.infoScript(id: DownloadFixture.otherVideoID),
                DownloadFixture.happyDownloadScript,
            ],
            probe: DownloadWritabilityProbe(results: [false], fallback: true)
        )
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForTerminals(2)

        let enqueuedIDs = try #require(harness.recorder.snapshots.first).pendingItems.map(\.id)
        #expect(harness.recorder.states(of: enqueuedIDs[0]) == [.queued, .failed(.destinationUnavailable)])
        #expect(harness.recorder.states(of: enqueuedIDs[1]).last == .finished(
            fileURL: URL(fileURLWithPath: DownloadFixture.finishedPath)
        ))
        // The failed row never even reached its prefetch: preflight precedes the spawn.
        #expect(harness.runner.spawnCount == 2)
        #expect(harness.probe.probedURLs == [harness.destination, harness.destination])
    }

    /// A benign re-paste of a file already on disk: the engine exits 0 having moved
    /// nothing. That must be the friendly dedicated case, and must import nothing.
    @Test("exit 0 without a file line is alreadyDownloaded and never fires onItemFinished")
    func exitZeroWithoutFileLineIsAlreadyDownloaded() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            .success(stdout: [DownloadFixture.quarterProgress]),
        ])
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .failed(.alreadyDownloaded))
        #expect(harness.recorder.finished.isEmpty)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// The signal ladder, unrequested half: nobody asked, so the kill is a FAULT and
    /// carries the engine's own diagnostic through `YtDlpProgressParser`.
    @Test("an unrequested signal termination fails the row with the signal diagnostic")
    func unrequestedSignalFailsTheRow() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            .signal(SIGKILL),
        ])
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .failed(
            .downloadFailed(detail: "terminated by signal \(SIGKILL)")
        ))
        #expect(harness.recorder.finished.isEmpty)
    }

    /// The requested half: the same signal-terminating script, but the person asked for
    /// it. It must read as a cancellation — no failure badge, no import.
    @Test("a requested cancel on a signal-terminating download reads as cancelled")
    func requestedCancelOnSignalTerminationIsCancellation() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            .signal(SIGTERM, stdout: [DownloadFixture.quarterProgress, DownloadFixture.halfProgress]),
        ])
        harness.interruptOnFirstDownloadTick { $0.cancelCurrent() }
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .cancelled)
        #expect(harness.recorder.states(of: id).last?.error == nil)
        #expect(harness.recorder.finished.isEmpty)
    }

    @Test("an unresolvable engine fails the row with toolMissing")
    func unresolvableToolFailsTheRow() async throws {
        let harness = DownloadQueueHarness(
            provider: FakeDownloadToolProvider(prepareError: DownloadError.toolMissing)
        )
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .failed(.toolMissing))
        #expect(harness.runner.spawnCount == 0)
    }

    @Test("a launch failure surfaces as its typed error")
    func launchFailureSurfacesTypedError() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            ToolProcessScript(launchError: DownloadError.toolMissing),
        ])
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .failed(.toolMissing))
    }

    @Test("removePending drops a pending row and the driver never picks it up")
    func removePendingDropsThePendingRow() async throws {
        let harness = DownloadQueueHarness()
        harness.service.pause()
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        let enqueuedIDs = try #require(harness.recorder.snapshots.last).pendingItems.map(\.id)
        harness.service.removePending(enqueuedIDs[1])
        harness.service.removePending(UUID())

        #expect(harness.recorder.latestSnapshot.pendingItems.map(\.id) == [enqueuedIDs[0]])
        #expect(harness.recorder.states(of: enqueuedIDs[1]) == [.queued, .cancelled])
    }

    @Test("movePending reorders the driver's pick order and clamps out-of-range targets")
    func movePendingReordersAndClamps() async throws {
        let harness = DownloadQueueHarness()
        harness.service.pause()
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
            downloadTestURL("https://www.youtube.com/watch?v=\(DownloadFixture.thirdVideoID)"),
        ]

        _ = await harness.service.enqueue(urls: urls)
        let enqueuedIDs = try #require(harness.recorder.snapshots.last).pendingItems.map(\.id)
        harness.service.movePending(enqueuedIDs[2], to: 0)
        #expect(harness.recorder.latestSnapshot.pendingItems.map(\.id)
            == [enqueuedIDs[2], enqueuedIDs[0], enqueuedIDs[1]])

        harness.service.movePending(enqueuedIDs[2], to: 99)

        #expect(harness.recorder.latestSnapshot.pendingItems.map(\.id)
            == [enqueuedIDs[0], enqueuedIDs[1], enqueuedIDs[2]])
    }

    /// Rows past the depth cap are refused outright — accepting them would only starve
    /// them, and they are NOT duplicates, so they are not counted as such.
    @Test("the queue depth cap refuses the overflow without counting it as a duplicate")
    func queueDepthCapRefusesOverflow() async throws {
        let harness = DownloadQueueHarness()
        harness.service.pause()
        let overflow = DownloadQueueLimits.maxQueueDepth + 5
        let urls = try DownloadFixture.generatedIDs(count: overflow)
            .map { try downloadTestURL("https://www.youtube.com/watch?v=\($0)") }

        let outcome = await harness.service.enqueue(urls: urls)

        #expect(outcome.added == DownloadQueueLimits.maxQueueDepth)
        #expect(outcome.duplicatesDropped == 0)
        #expect(harness.recorder.latestSnapshot.count == DownloadQueueLimits.maxQueueDepth)
    }
}
