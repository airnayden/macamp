// `DownloadQueueService` — enqueue, dedup, playlist expansion/confirmation, and the
// happy download path, all driven by a scripted `FakeToolProcessRunner`.
//
// Every scenario is hermetic: no `Process`, no network, no disk. The runner answers each
// spawn from a script, so a whole download is a fixed list of engine output lines and one
// termination value. Transport (pause/cancel/failure) lives in the sibling file.
//
// Tests that assert only ENQUEUE bookkeeping call `pause()` first. That is not a trick:
// it parks the driver so the rows under test stay in the queue for the assertion, instead
// of racing the pump that would otherwise dequeue and retire them mid-test.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("Download queue service")
struct DownloadQueueServiceTests {
    /// The plan's happy path, end to end: the exact state ladder a row walks, the file
    /// the engine reported, and the import seam firing exactly once with it.
    @Test("a single URL walks queued → fetchingMetadata → downloading → postProcessing → finished")
    func singleURLWalksTheFullLadder() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        let url = try downloadTestURL(DownloadFixture.watchURL)

        let outcome = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        #expect(outcome == EnqueueOutcome(added: 1, duplicatesDropped: 0))
        let id = try harness.firstEnqueuedID()
        let finishedURL = URL(fileURLWithPath: DownloadFixture.finishedPath)
        #expect(harness.recorder.states(of: id) == [
            .queued,
            .fetchingMetadata,
            .downloading(fraction: 0.25, speedBytesPerSec: 131_072, etaSeconds: 6),
            .downloading(fraction: 0.5, speedBytesPerSec: 262_144, etaSeconds: 3),
            .postProcessing(fraction: nil),
            .finished(fileURL: finishedURL),
        ])
        #expect(harness.recorder.finished.count == 1)
        #expect(harness.recorder.finished.first?.fileURL == finishedURL)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    /// The plural snapshot vocabulary, measured on the live service rather than on the
    /// value type: an in-flight row is published INSIDE
    /// ``DownloadQueueSnapshot/activeItems`` as a one-element list, never as a singular
    /// optional. Concurrency is still one here — this pins the shape a parallel driver
    /// widens into, so a regression to a singular field fails here rather than in the UI.
    @Test("an in-flight row is published as a one-element activeItems list")
    func inFlightRowIsPublishedInTheActiveList() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let enqueuedID = try harness.firstEnqueuedID()
        let inFlight = try #require(harness.recorder.snapshots.first { !$0.activeItems.isEmpty })
        #expect(inFlight.activeItems.map(\.id) == [enqueuedID])
        #expect(inFlight.count == 1)
        #expect(harness.recorder.latestSnapshot.activeItems.isEmpty)
    }

    /// The row the confirmation sheet and the sidebar both render from — filled by the
    /// LAZY `-J` at dequeue, never by an upfront pass over the whole queue.
    @Test("metadata is fetched lazily at dequeue and enriches the row in place")
    func metadataEnrichesTheRowInPlace() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let finishedItem = try #require(harness.recorder.finished.first?.item)
        #expect(finishedItem.title == "Never Gonna Give You Up")
        #expect(finishedItem.uploader == "Rick Astley")
        #expect(finishedItem.durationSeconds == 213)
        #expect(finishedItem.thumbnailURL?.lastPathComponent == "hq.jpg")
        // Two spawns for one row: the prefetch, then the transfer. Never more.
        #expect(harness.runner.spawnCount == 2)
    }

    /// N rows must cost N prefetches — one each, at ITS dequeue — never N upfront.
    @Test("a two-row queue prefetches at dequeue, one row at a time")
    func prefetchIsPerRowNotUpfront() async throws {
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
            DownloadFixture.infoScript(id: DownloadFixture.otherVideoID),
            DownloadFixture.happyDownloadScript,
        ])
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForTerminals(2)

        #expect(harness.runner.spawnCount == 4)
        // Spawn order proves seriality: row one's pair completes before row two starts.
        let prefetchIndexes = harness.runner.spawnRequests.enumerated()
            .filter { $0.element.arguments.contains("--flat-playlist") }
            .map(\.offset)
        #expect(prefetchIndexes == [0, 2])
        #expect(harness.recorder.finished.count == 2)
    }

    @Test("a duplicate canonical id in the same paste is silently dropped and counted")
    func duplicatesInOnePasteAreDropped() async throws {
        let harness = DownloadQueueHarness()
        harness.service.pause()
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.shortWatchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        let outcome = await harness.service.enqueue(urls: urls)

        #expect(outcome == EnqueueOutcome(added: 2, duplicatesDropped: 1))
        #expect(harness.recorder.latestSnapshot.pendingItems.count == 2)
    }

    @Test("a URL that names neither a video nor a playlist is ignored, not counted")
    func unrecognizedURLsAreIgnored() async throws {
        let harness = DownloadQueueHarness()
        let urls = try [
            downloadTestURL("https://example.com/not-youtube"),
            downloadTestURL("https://www.youtube.com/watch?v=tooshort"),
        ]

        let outcome = await harness.service.enqueue(urls: urls)

        #expect(outcome == .zero)
        #expect(harness.runner.spawnCount == 0)
    }

    /// The cap exists so one pasted mega-playlist cannot balloon the queue. 600 entries
    /// must arrive as 500 HELD entries flagged `capped` — and nothing queued yet.
    @Test("a 600-entry playlist is held, capped at 500, and flagged")
    func playlistIsCappedAndHeld() async throws {
        let ids = DownloadFixture.generatedIDs(count: 600)
        let harness = DownloadQueueHarness(scripts: [
            .success(stdout: [DownloadFixture.playlist(ids: ids)]),
        ])
        let url = try downloadTestURL(DownloadFixture.playlistURL)

        let outcome = await harness.service.enqueue(urls: [url])

        let held = try #require(outcome.pendingPlaylist)
        #expect(held.count == DownloadQueueLimits.maxPlaylistExpansion)
        #expect(held.capped)
        #expect(outcome.added == 0)
        // Held, not queued: exactly one spawn (the expansion), no transfer.
        #expect(harness.runner.spawnCount == 1)
        #expect(harness.recorder.latestSnapshot == .empty)
    }

    @Test("a short playlist is held uncapped and confirmation is what queues it")
    func confirmationQueuesHeldEntries() async throws {
        let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID, DownloadFixture.thirdVideoID]
        let harness = DownloadQueueHarness(scripts: [
            .success(stdout: [DownloadFixture.playlist(ids: ids)]),
        ])
        harness.service.pause()
        let url = try downloadTestURL(DownloadFixture.playlistURL)

        let outcome = await harness.service.enqueue(urls: [url])
        let held = try #require(outcome.pendingPlaylist)
        #expect(held.count == 3)
        #expect(!held.capped)

        let confirmed = await harness.service.confirmPlaylist(held.token)

        #expect(confirmed == EnqueueOutcome(added: 3, duplicatesDropped: 0))
        #expect(harness.recorder.latestSnapshot.pendingItems.count == 3)
    }

    /// Confirmation dedups against the queue as it is NOW — the sheet may have been open
    /// while the person pasted the same video separately.
    @Test("confirmation dedups against rows queued while the sheet was open")
    func confirmationDedupsAgainstTheLiveQueue() async throws {
        let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID]
        let harness = DownloadQueueHarness(scripts: [
            .success(stdout: [DownloadFixture.playlist(ids: ids)]),
        ])
        harness.service.pause()
        let playlist = try downloadTestURL(DownloadFixture.playlistURL)
        let single = try downloadTestURL(DownloadFixture.watchURL)

        let outcome = await harness.service.enqueue(urls: [playlist, single])
        let held = try #require(outcome.pendingPlaylist)
        let confirmed = await harness.service.confirmPlaylist(held.token)

        #expect(outcome.added == 1)
        #expect(held.count == 2)
        #expect(confirmed == EnqueueOutcome(added: 1, duplicatesDropped: 1))
    }

    /// The plan's mixed paste: singles land immediately AND the playlist waits, in ONE
    /// outcome. An enum return would have forced the caller to lose two of these facts.
    @Test("a mixed paste reports added, dropped, and a pending playlist at once")
    func mixedPasteReportsEverythingAtOnce() async throws {
        let ids = DownloadFixture.generatedIDs(count: 4)
        let harness = DownloadQueueHarness(scripts: [
            .success(stdout: [DownloadFixture.playlist(ids: ids)]),
        ])
        harness.service.pause()
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
            downloadTestURL(DownloadFixture.shortWatchURL),
            downloadTestURL(DownloadFixture.playlistURL),
        ]

        let outcome = await harness.service.enqueue(urls: urls)

        #expect(outcome.added == 2)
        #expect(outcome.duplicatesDropped == 1)
        let held = try #require(outcome.pendingPlaylist)
        #expect(held.count == 4)
        #expect(!held.capped)
    }

    @Test("a token that was never issued confirms nothing")
    func unknownTokenReturnsZero() async {
        let harness = DownloadQueueHarness()

        let confirmed = await harness.service.confirmPlaylist(UUID())

        #expect(confirmed == .zero)
    }

    /// A confirmation the person walked away from must not resurrect on the next paste.
    @Test("a stale token confirms nothing once a later enqueue superseded it")
    func staleTokenReturnsZero() async throws {
        let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID]
        let harness = DownloadQueueHarness(scripts: [
            .success(stdout: [DownloadFixture.playlist(ids: ids)]),
            .success(stdout: [DownloadFixture.playlist(ids: [DownloadFixture.thirdVideoID])]),
        ])
        harness.service.pause()
        let url = try downloadTestURL(DownloadFixture.playlistURL)

        let first = await harness.service.enqueue(urls: [url])
        let staleToken = try #require(first.pendingPlaylist?.token)
        let second = await harness.service.enqueue(urls: [url])

        let confirmed = await harness.service.confirmPlaylist(staleToken)

        #expect(confirmed == .zero)
        #expect(second.pendingPlaylist?.token != staleToken)
    }

    /// The whole point of the confirmation seam: expansion queues NOTHING on its own.
    @Test("an unconfirmed expansion never spawns a transfer")
    func unconfirmedExpansionNeverDownloads() async throws {
        let harness = DownloadQueueHarness(scripts: [
            .success(stdout: [DownloadFixture.playlist(ids: [DownloadFixture.videoID])]),
        ])
        let url = try downloadTestURL(DownloadFixture.playlistURL)

        _ = await harness.service.enqueue(urls: [url])
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.runner.spawnCount == 1)
        #expect(harness.recorder.progress.isEmpty)
    }

    /// A playlist listing the engine could not produce must not present itself as an
    /// empty-but-complete playlist.
    @Test("a failed playlist listing yields no pending playlist")
    func failedListingYieldsNoPendingPlaylist() async throws {
        let harness = DownloadQueueHarness(scripts: [.exit(status: 1, stderr: ["ERROR: unavailable"])])
        let url = try downloadTestURL(DownloadFixture.playlistURL)

        let outcome = await harness.service.enqueue(urls: [url])

        #expect(outcome == .zero)
    }
}
