// The queue-level proof that an interruption actually reclaims the row's staging
// footprint — the end-to-end reproduction of the truncated-download defect.
//
// These cases use ONLY the public transport surface (`cancelAll()`, `cancel(itemID:)`,
// `pause()`) and a seeded staging directory, so they fail against the code that shipped
// the defect rather than merely failing to compile. That is what makes them the red half
// of red→green: the shipped `requestCancellation()` had no phase awareness and no
// cleanup, so the partial output container survived every interruption and the next
// attempt at that video adopted it as finished.
//
// The interruptions are DETERMINISTIC, not timed: they run on the `onItemProgress` seam,
// and the driver AWAITS each publish before reading the next engine line.
import Foundation
import PlayerCoreTestSupport
@testable import Services
import Testing

@MainActor
@Suite("Download queue staging hygiene")
struct DownloadQueueStagingHygieneTests {
    /// `cancelAll()` is also what the quit teardown calls, so this covers the path on
    /// which the driver never runs again and only a synchronous purge can help.
    @Test("cancelAll mid-download reclaims the in-flight row's whole footprint")
    func cancelAllReclaimsTheInFlightFootprint() async throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)
        let harness = DownloadQueueHarness(
            scripts: [DownloadFixture.infoScript(), DownloadFixture.happyDownloadScript],
            staging: staging
        )
        let atCancelTime = SurvivingArtifactsBox()
        harness.interruptOnFirstDownloadTick { service in
            service.cancelAll()
            atCancelTime.record(StagingFixture.ownedNames.filter {
                StagingFixture.exists($0, in: staging)
            })
        }
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        // Sampled on the SAME main-actor turn as the cancel, before any driver could
        // settle. The driver purges again when it applies the outcome, so a check taken
        // only after the run passes even when the synchronous purge is wrong or absent —
        // and the synchronous one is the only one a quit teardown ever reaches.
        #expect(atCancelTime.names == [], "survived the synchronous purge: \(atCancelTime.names)")
        for name in StagingFixture.ownedNames {
            #expect(!StagingFixture.exists(name, in: staging), "\(name) survived a cancel")
        }
    }

    /// Refill-stop pause performs NO purge, because it performs no interruption: the row
    /// it was raised against runs to completion and reports `.finished`.
    ///
    /// The assertion is "untouched", not "gone", and the distinction is the honest one.
    /// In production a successful run empties its own staging — yt-dlp MOVES the output
    /// to the destination and cleans its intermediates — so there is nothing for MacAMP
    /// to reclaim. `FakeToolProcessRunner` is not yt-dlp and never touches the
    /// filesystem, so the seeded files are exactly the ones a purge would have taken.
    /// Their survival is therefore the only available evidence that no purge ran, and it
    /// fails loudly against the retired contract, which dropped the container here.
    @Test("pause mid-download lets the row finish and purges nothing")
    func pauseLetsTheRowFinishAndPurgesNothing() async throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)
        let harness = DownloadQueueHarness(
            scripts: [DownloadFixture.infoScript(), DownloadFixture.happyDownloadScript],
            staging: staging
        )
        harness.interruptOnFirstDownloadTick { $0.pause() }
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForPausedIdle()

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .finished(
            fileURL: URL(fileURLWithPath: DownloadFixture.finishedPath)
        ))
        #expect(harness.recorder.finished.map(\.item.id) == [id])
        for name in StagingFixture.ownedNames {
            #expect(StagingFixture.exists(name, in: staging), "pause purged \(name)")
        }
    }

    /// The queue-level binding for `.adoptableOutputs`, which pause no longer produces.
    ///
    /// A non-zero exit is the generic-failure branch, and a failure is the state a person
    /// retries most — so the container a retry would wrongly ADOPT goes while the
    /// resumable `.part` and its bookkeeping stay. This is now the only queue-level
    /// producer of that scope, and without this case nothing would hold it.
    @Test("a failed download drops the adoptable container and keeps the resumable partial")
    func failureDropsTheContainerAndKeepsThePartial() async throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        try StagingFixture.seedAll(StagingFixture.ownedNames, in: staging)
        let harness = DownloadQueueHarness(
            scripts: [
                DownloadFixture.infoScript(),
                .exit(status: 1, stderr: ["ERROR: unable to download video data"]),
            ],
            staging: staging
        )
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last?.error != nil)
        #expect(!StagingFixture.exists(StagingFixture.adoptableContainer, in: staging))
        #expect(!StagingFixture.exists(StagingFixture.muxScratch, in: staging))
        #expect(StagingFixture.exists(StagingFixture.resumablePartial, in: staging))
        #expect(StagingFixture.exists(StagingFixture.resumeState, in: staging))
    }

    /// Per-item cancellation, measured where it is cheapest to get wrong: two rows in
    /// flight, one cancelled, and the staging directory holding BOTH footprints.
    ///
    /// The sibling's five files surviving is the whole point. A shared cancellation latch
    /// purges every active row at once, so this fails against the provisional
    /// `cancel(itemID:)` that shipped with the per-item driver plumbing — which is
    /// exactly the window this case exists to close.
    @Test("cancelling one of two in-flight rows purges only that row's staging")
    func cancelPurgesOnlyTheNamedRowsStaging() async throws {
        let staging = try StagingFixture.makeDirectory()
        defer { StagingFixture.remove(staging) }
        let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID]
        for videoID in ids {
            try StagingFixture.seedAll(StagingFixture.ownedNames(forVideoID: videoID), in: staging)
        }
        let harness = ConcurrentDownloadHarness(
            videoIDs: ids,
            maxConcurrent: { 2 },
            staging: staging
        )
        let cancelled = CancelledRowBox()
        let atCancelTime = SurvivingArtifactsBox()
        harness.onFirstDownloadingRow { service, id in
            guard let item = service.active.first(where: { $0.id == id }) else { return }
            cancelled.capture(item.canonicalVideoID)
            service.cancel(itemID: id)
            atCancelTime.record(ids.flatMap { StagingFixture.ownedNames(forVideoID: $0) }
                .filter { StagingFixture.exists($0, in: staging) })
        }

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(2)

        let cancelledVideoID = try #require(cancelled.videoID)
        let survivor = try #require(ids.first { $0 != cancelledVideoID })
        #expect(harness.recorder.finished.map(\.item.canonicalVideoID) == [survivor])
        // Sampled on the cancel's own main-actor turn, for the same reason as above: the
        // driver's second purge would otherwise answer for a wrong synchronous scope.
        #expect(atCancelTime.names == StagingFixture.ownedNames(forVideoID: survivor))
        for name in StagingFixture.ownedNames(forVideoID: cancelledVideoID) {
            #expect(!StagingFixture.exists(name, in: staging), "\(name) survived a per-item cancel")
        }
        for name in StagingFixture.ownedNames(forVideoID: survivor) {
            #expect(StagingFixture.exists(name, in: staging), "a sibling's \(name) was purged")
        }
    }
}
