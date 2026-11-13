// The parallel driver: real overlap, a reentrancy-safe pump, per-row routing, and the
// single-authority rule that makes an in-place enrichment reach `onItemFinished`.
//
// Everything here is deterministic. Overlap is forced by a barrier rather than inferred
// from timing; the snapshot-per-pass and reentrancy cases run entirely on synchronous
// main-actor stretches, so a driver task cannot have interleaved between the act and the
// assertion.
import Foundation
import PlayerCoreTestSupport
@testable import Services
import Testing

@MainActor
@Suite("Download queue concurrency")
struct DownloadQueueConcurrencyTests {
    static let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID, DownloadFixture.thirdVideoID]

    /// Three transfers genuinely in flight at once, proven two independent ways: a
    /// barrier none of them may pass until all three have reached it, and a recorded
    /// sample sequence that is not three contiguous blocks.
    @Test("three rows transfer at once and their progress samples interleave")
    func threeRowsTransferAtOnce() async {
        let barrier = TransferBarrier(count: 3)
        let harness = ConcurrentDownloadHarness(
            videoIDs: Self.ids,
            maxConcurrent: { 3 },
            gate: { await barrier.arrive($0) }
        )

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(3)

        let timedOut = await barrier.timedOut
        let arrivals = await barrier.arrivals
        #expect(!timedOut, "a serial driver cannot reach the third arrival")
        #expect(Set(arrivals) == Set(Self.ids))
        #expect(harness.recorder.peakActiveCount == 3)
        #expect(harness.recorder.downloadingRunCount > 3, "three contiguous blocks would mean no overlap")
        #expect(harness.recorder.finished.count == 3)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// The reentrancy guard. `append()` fired from inside a settle re-enters the pump
    /// while the settling row's driver is still unwinding; the slot count must hold
    /// across every one of those passes.
    ///
    /// BOTH seams are sampled, and the snapshot one is the load-bearing half: the row
    /// seam fires BEFORE the reentrant pump refills, so an observer watching only it
    /// never sees the moment an extra driver would exist. The pump's own
    /// `emitQueueChanged()` lands immediately after the refill, with the outgoing
    /// driver's retirement still pending — which is the exact window the ordering inside
    /// `runItem` exists to close.
    @Test("an append during a settle never spawns more drivers than there are slots")
    func appendDuringSettleNeverOverspawns() async {
        let limit = 2
        let extraIDs = DownloadFixture.generatedIDs(count: 3)
        let harness = ConcurrentDownloadHarness(
            videoIDs: Self.ids + extraIDs,
            maxConcurrent: { limit }
        )
        let observer = ConcurrencyObserver()
        let service = harness.service
        let sink = harness.recorder
        let refill = OneShotLatch()
        service.onQueueChanged = { snapshot in
            sink.record(snapshot: snapshot)
            MainActor.assumeIsolated {
                observer.observe(drivers: service.drivers.count, active: service.active.count)
            }
        }
        service.onItemProgress = { id, state in
            sink.record(id: id, state: state)
            MainActor.assumeIsolated {
                observer.observe(drivers: service.drivers.count, active: service.active.count)
                guard state.isTerminal, refill.fire() else { return }
                service.append(extraIDs.map(Self.item(for:)))
            }
        }

        _ = await harness.enqueue(ids: Self.ids)
        await harness.waitForTerminals(Self.ids.count + extraIDs.count)

        #expect(observer.peakDrivers <= limit, "observed \(observer.peakDrivers) drivers for \(limit) slots")
        #expect(observer.peakActive <= limit)
        #expect(observer.sampleCount > 0, "the invariant was never actually observed")
        #expect(harness.recorder.finished.count == Self.ids.count + extraIDs.count)
    }

    /// Every in-flight row publishes on its own id, and a sample that arrives for a row
    /// that has already settled is dropped rather than resurrecting it.
    @Test("progress routes per row and a settled row's late sample is dropped")
    func progressRoutesPerRowAndDropsSettledSamples() async throws {
        let harness = ConcurrentDownloadHarness(videoIDs: Self.ids, maxConcurrent: { 3 })

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(3)

        let finishedIDs = harness.recorder.finished.map(\.item.id)
        #expect(finishedIDs.count == 3)
        for id in finishedIDs {
            #expect(harness.recorder.downloadingIDs.contains(id))
        }

        let settled = try #require(finishedIDs.first)
        let before = harness.recorder.states(of: settled)
        harness.service.publishProgress(
            .downloading(fraction: 0.9, speedBytesPerSec: 1, etaSeconds: 1),
            for: settled
        )

        #expect(harness.recorder.states(of: settled) == before)
        #expect(before.last?.isTerminal == true)
    }

    /// Enrichment is addressed by id, so a row's `-J` document can only ever land on
    /// that row. Distinct titles per id are what make a crossed write visible as the
    /// WRONG title rather than as a missing one.
    @Test("enrichment for one row never mutates another")
    func enrichmentNeverCrossesRows() async {
        let titles = Dictionary(uniqueKeysWithValues: Self.ids.map { ($0, "Title for \($0)") })
        let harness = ConcurrentDownloadHarness(
            videoIDs: Self.ids,
            titles: titles,
            maxConcurrent: { 3 }
        )

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(3)

        #expect(harness.recorder.finished.count == 3)
        for event in harness.recorder.finished {
            #expect(event.item.title == titles[event.item.canonicalVideoID])
            #expect(event.item.uploader == "Uploader \(event.item.canonicalVideoID)")
        }
    }

    /// Single item authority: a write into `active` AFTER the transfer has started still
    /// reaches `onItemFinished`.
    ///
    /// The row was enqueued with no title at all, so the driver's own token carries
    /// `nil`. Reading the finished title back proves the outcome path re-read `active`
    /// by id rather than reporting the copy it was handed at dequeue — which is what the
    /// download history will depend on.
    @Test("an enrichment landing after the transfer starts reaches onItemFinished")
    func lateEnrichmentReachesTheFinishedSeam() async throws {
        let lateTitle = "Renamed while transferring"
        let harness = ConcurrentDownloadHarness(videoIDs: [DownloadFixture.videoID], maxConcurrent: { 1 })
        let service = harness.service
        let sink = harness.recorder
        let latch = OneShotLatch()
        service.onItemProgress = { id, state in
            sink.record(id: id, state: state)
            guard case .downloading = state, latch.fire() else { return }
            MainActor.assumeIsolated {
                guard let index = service.active.firstIndex(where: { $0.id == id }) else { return }
                service.active[index].title = lateTitle
            }
        }

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(1)

        let finished = try #require(harness.recorder.finished.first)
        #expect(finished.item.title == lateTitle)
    }

    /// The format is stamped into the authoritative row at the moment the driver reads
    /// the setting, so a finished row reports the container it actually produced.
    @Test("every finished row carries the format it was dequeued with")
    func finishedRowsCarryTheirResolvedFormat() async {
        let format = DownloadFormat.audio(.mp3, .high)
        let harness = ConcurrentDownloadHarness(
            videoIDs: Self.ids,
            maxConcurrent: { 3 },
            format: { format }
        )

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(3)

        #expect(harness.recorder.finished.count == 3)
        for event in harness.recorder.finished {
            #expect(event.item.resolvedFormat == format)
        }
    }

    /// One pass, one snapshot. `append` publishes the membership change and the pump
    /// publishes the fill; three slots opening is not three renders.
    ///
    /// Both calls run on one unbroken synchronous main-actor stretch, so no driver task
    /// can have emitted anything between them.
    @Test("filling three slots emits exactly one snapshot for the pass")
    func fillingThreeSlotsEmitsOneSnapshot() throws {
        let harness = ConcurrentDownloadHarness(videoIDs: Self.ids, maxConcurrent: { 3 })

        harness.service.append(Self.ids.map(Self.item(for:)))

        #expect(harness.recorder.snapshots.count == 2)
        let membership = try #require(harness.recorder.snapshots.first)
        #expect(membership.activeItems.isEmpty)
        #expect(membership.pendingItems.count == 3)
        let filled = try #require(harness.recorder.snapshots.last)
        #expect(filled.activeItems.count == 3)
        #expect(filled.pendingItems.isEmpty)
    }

    /// A pass that fills nothing publishes nothing — otherwise every settle would
    /// re-render the list a second time for no change.
    @Test("a pump pass that fills no slot emits no snapshot")
    func anEmptyPumpPassEmitsNothing() {
        let harness = ConcurrentDownloadHarness(videoIDs: Self.ids, maxConcurrent: { 3 })

        harness.service.pump()

        #expect(harness.recorder.snapshots.isEmpty)
    }

    @Test("the concurrency limit is clamped into the supported range", arguments: [
        (0, 1), (-5, 1), (1, 1), (3, 3), (4, 4), (9, DownloadQueueLimits.maxConcurrentDownloads),
    ])
    func concurrencyLimitIsClamped(requested: Int, expected: Int) {
        let harness = ConcurrentDownloadHarness(videoIDs: [], maxConcurrent: { requested })

        #expect(harness.service.concurrencyLimit() == expected)
    }

    static func item(for videoID: String) -> DownloadItem {
        DownloadItem(
            canonicalVideoID: videoID,
            sourceURL: URL(fileURLWithPath: "/dev/null")
        )
    }
}

/// Records the highest driver and slot counts ever observed, and how often it looked.
///
/// The sample count is asserted too: an observer that never ran would report a peak of
/// zero, which passes a `<=` bound while measuring nothing.
final class ConcurrencyObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers = 0
    private var active = 0
    private var samples = 0

    func observe(drivers driverCount: Int, active activeCount: Int) {
        lock.withLock {
            drivers = max(drivers, driverCount)
            active = max(active, activeCount)
            samples += 1
        }
    }

    var peakDrivers: Int {
        lock.withLock { drivers }
    }

    var peakActive: Int {
        lock.withLock { active }
    }

    var sampleCount: Int {
        lock.withLock { samples }
    }
}
