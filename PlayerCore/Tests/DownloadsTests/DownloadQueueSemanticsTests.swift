// Pause, cancel, failure and live concurrency — all four measured ABOVE one slot, where
// they are cheapest to get wrong.
//
// The serial suites state the same contracts through `DownloadQueueHarness`, whose
// runner hands out scripts POSITIONALLY and therefore only describes a run with a fixed
// spawn order. Everything here needs several rows genuinely in flight at once, so it
// runs on `VideoScriptedRunner`, which answers by canonical video id instead.
//
// The interruptions are DETERMINISTIC, not timed: they ride the `onItemProgress` seam,
// and the driver AWAITS each publish before reading the next engine line.
import Foundation
import PlayerCoreTestSupport
@testable import Services
import Testing

@MainActor
@Suite("Download queue pause and cancel semantics")
struct DownloadQueueSemanticsTests {
    static let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID, DownloadFixture.thirdVideoID]

    /// Refill-stop with the slots full: two rows transferring, one waiting. Pause stops
    /// the third from ever starting and lets the other two run to completion.
    ///
    /// `transferCount == 2` is what separates this from a queue that merely finished:
    /// the held row never reached a transfer spawn at all.
    @Test("pause lets two in-flight rows finish while the pending row holds")
    func pauseLetsTwoInFlightRowsFinish() async {
        let harness = ConcurrentDownloadHarness(videoIDs: Self.ids, maxConcurrent: { 2 })
        harness.onFirstDownloadingRow { service, _ in service.pause() }

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(2)
        await harness.waitUntil { harness.recorder.latestSnapshot.activeItems.isEmpty }

        let snapshot = harness.recorder.latestSnapshot
        #expect(snapshot.isPaused)
        #expect(snapshot.activeItems.isEmpty)
        #expect(snapshot.pendingItems.count == 1)
        #expect(harness.recorder.finished.count == 2)
        #expect(harness.runner.transferCount == 2)
    }

    /// A cancel aimed at one row is answered by that row alone: its sibling keeps
    /// transferring and finishes, and the row behind them is still picked up.
    ///
    /// Against a shared cancellation latch every active row stops here, so `finished`
    /// would be short by one and the sibling would report `.cancelled`.
    @Test("cancelling one in-flight row leaves its sibling running")
    func cancelStopsExactlyOneRow() async throws {
        let harness = ConcurrentDownloadHarness(videoIDs: Self.ids, maxConcurrent: { 2 })
        let cancelled = CancelledRowBox()
        harness.cancelFirstDownloadingRow(into: cancelled)

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(3)

        let cancelledVideoID = try #require(cancelled.videoID)
        let finishedIDs = harness.recorder.finished.map(\.item.canonicalVideoID)
        #expect(finishedIDs.count == 2)
        #expect(!finishedIDs.contains(cancelledVideoID))
        #expect(Set(finishedIDs) == Set(Self.ids).subtracting([cancelledVideoID]))
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// One row killed by an uncaught signal nobody asked for is a FAULT, and it is that
    /// row's fault alone — its two siblings finish untouched.
    ///
    /// The diagnostic comes from `YtDlpProgressParser`, the pure map, which is asked
    /// whether a cancellation was REQUESTED for this row. A shared latch would let a
    /// sibling's cancel rewrite this row's fault as a cancellation and vice versa.
    @Test("one row's signal failure never drains its siblings")
    func oneRowsFailureNeverDrainsSiblings() async throws {
        let failing = DownloadFixture.otherVideoID
        let harness = ConcurrentDownloadHarness(
            videoIDs: Self.ids,
            terminations: [failing: ProcessTermination(status: SIGKILL, reason: .uncaughtSignal)],
            maxConcurrent: { 3 }
        )

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(3)

        let failedID = try #require(harness.idOfRow(videoID: failing))
        #expect(harness.recorder.states(of: failedID).last == .failed(
            .downloadFailed(detail: "terminated by signal \(SIGKILL)")
        ))
        #expect(Set(harness.recorder.finished.map(\.item.canonicalVideoID))
            == Set(Self.ids).subtracting([failing]))
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// The limit is read at every refill, so lowering it mid-queue never interrupts
    /// anything: the rows already running finish, and the pump simply stops refilling
    /// until the count falls back under the new limit.
    ///
    /// The assertion is the snapshot in which the FOURTH row first appears. It must show
    /// exactly one row in flight — a limit captured once instead of re-read would have
    /// filled that slot the moment the first row settled, with two siblings still
    /// transferring, and the snapshot would show three.
    @Test("lowering maxConcurrent mid-queue finishes the extant rows and refills at one")
    func loweringMaxConcurrentFinishesExtantAndRefillsAtOne() async throws {
        let fourth = "PLVID000042"
        let ids = Self.ids + [fourth]
        let limit = ConcurrencyLimitBox(3)
        let harness = ConcurrentDownloadHarness(videoIDs: ids, maxConcurrent: { limit.value })
        harness.onFirstTerminal { limit.value = 1 }

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(4)

        #expect(harness.recorder.peakActiveCount == 3)
        #expect(harness.recorder.finished.count == 4)
        let refill = try #require(harness.recorder.snapshots.first { snapshot in
            snapshot.activeItems.contains { $0.canonicalVideoID == fourth }
        })
        #expect(refill.activeItems.count == 1)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// Cancelling is still available while paused, and it is the only way to drop a row
    /// that refill-stop deliberately leaves running.
    @Test("a row cancelled while paused stops and the queue stays parked")
    func cancelWhilePausedStopsThatRowAndStaysParked() async throws {
        let harness = ConcurrentDownloadHarness(videoIDs: Self.ids, maxConcurrent: { 2 })
        let cancelled = CancelledRowBox()
        harness.onFirstDownloadingRow { service, id in
            service.pause()
            guard let item = service.active.first(where: { $0.id == id }) else { return }
            cancelled.capture(item.canonicalVideoID)
            service.cancel(itemID: id)
        }

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(2)
        await harness.waitUntil { harness.recorder.latestSnapshot.activeItems.isEmpty }

        // Two slots, three rows: the first two ids were in flight and the third held.
        let cancelledVideoID = try #require(cancelled.videoID)
        let sibling = try #require(Self.ids.prefix(2).first { $0 != cancelledVideoID })
        let snapshot = harness.recorder.latestSnapshot
        #expect(snapshot.isPaused)
        #expect(snapshot.activeItems.isEmpty)
        #expect(snapshot.pendingItems.map(\.canonicalVideoID) == [Self.ids[2]])
        #expect(harness.recorder.finished.map(\.item.canonicalVideoID) == [sibling])
    }
}
