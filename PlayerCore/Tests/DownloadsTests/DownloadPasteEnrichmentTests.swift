// Paste-time decoration, and the authority rule between it and `-J`.
//
// Every test here drives the REAL `DownloadQueueService` through its public surface —
// `pause()`, `enqueue(urls:)`, `confirmPlaylist(_:)`, `removePending(_:)`, `resume()` —
// and reads the published snapshots. Nothing reaches an internal method, so each claim
// is about a sequence a person can actually produce.
//
// The queue is PAUSED first wherever a pending row is the subject. `append()` pumps
// synchronously, so an unpaused queue promotes a freshly pasted single to `active`
// before the lookup can answer — and decoration deliberately writes to pending rows
// only. Pausing is what makes the waiting row the thing under test rather than a race.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@Suite("Paste-time enrichment")
@MainActor
struct DownloadPasteEnrichmentTests {
    private static let pasteTitle = "Paste Title"
    private static let pasteChannel = "Paste Channel"
    private static let thumbnailString = "https://i.ytimg.com/vi/\(DownloadFixture.videoID)/hq.jpg"

    private static func thumbnail() throws -> URL {
        try downloadTestURL(thumbnailString)
    }

    private static func fetcher(
        title: String = pasteTitle,
        channel: String? = pasteChannel,
        latency: Duration = .zero
    ) throws -> FakeOEmbedFetcher {
        let payload = try OEmbedPayload(title: title, authorName: channel, thumbnailURL: thumbnail())
        return FakeOEmbedFetcher(payloads: [DownloadFixture.videoID: payload], latency: latency)
    }

    // MARK: (a) Singles

    /// One paste, one keyless lookup, and the waiting row stops showing a raw id.
    @Test func pasteFillsAWaitingRowThroughOneOEmbedLookup() async throws {
        let oEmbed = try Self.fetcher()
        let harness = DownloadQueueHarness(oEmbed: oEmbed)
        harness.service.pause()

        _ = try await harness.service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        await harness.waitUntil { harness.recorder.latestSnapshot.pendingItems.first?.title != nil }

        let expectedThumbnail = try Self.thumbnail()
        let row = try #require(harness.recorder.latestSnapshot.pendingItems.first)
        #expect(row.title == Self.pasteTitle)
        #expect(row.uploader == Self.pasteChannel)
        #expect(row.thumbnailURL == expectedThumbnail)
        #expect(oEmbed.requestedVideoIDs == [DownloadFixture.videoID])
        // No engine was touched: a paste spawns nothing.
        #expect(harness.runner.spawnCount == 0)
    }

    /// A lookup that answers nothing leaves the row exactly as it was — the failure
    /// shape the QA scenario calls "identical to today".
    ///
    /// The publication count is asserted alongside the fields because "unchanged" has
    /// two halves and only one of them is visible in the values: a `nil` answer must
    /// also cost the queue list ZERO passes, and a snapshot republished with identical
    /// contents still invalidates every `@Observable` reader of it.
    @Test func aLookupThatAnswersNothingLeavesTheRowUntouched() async throws {
        let oEmbed = FakeOEmbedFetcher()
        let harness = DownloadQueueHarness(oEmbed: oEmbed)
        harness.service.pause()

        _ = try await harness.service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        let publicationsAfterPaste = harness.recorder.snapshots.count
        await harness.waitUntil { oEmbed.fetchCallCount == 1 }
        try await Task.sleep(for: .milliseconds(60))

        let row = try #require(harness.recorder.latestSnapshot.pendingItems.first)
        #expect(row.title == nil)
        #expect(row.displayTitle == DownloadFixture.videoID)
        #expect(row.uploader == nil)
        #expect(row.thumbnailURL == nil)
        #expect(harness.recorder.snapshots.count == publicationsAfterPaste)
    }

    /// A decoration ADDS; it never replaces.
    ///
    /// The sequence is real rather than contrived: `--flat-playlist -J` can name an
    /// entry's channel without naming its title, so that row reaches the queue with a
    /// channel already on it and a title still missing — which is exactly the state in
    /// which the field-level rule is observable. The lookup must fill the title and
    /// leave the channel the listing supplied alone.
    @Test func aDecorationFillsEmptyFieldsAndNeverOverwritesAFilledOne() async throws {
        let flatChannel = "Flat Listing Channel"
        let document = """
        {"_type":"playlist","id":"PLmacampdownloads","entries":[\
        {"_type":"url","id":"\(DownloadFixture.videoID)","channel":"\(flatChannel)"}]}
        """
        let oEmbed = try Self.fetcher()
        let harness = DownloadQueueHarness(scripts: [.success(stdout: [document])], oEmbed: oEmbed)
        harness.service.pause()

        let outcome = try await harness.service.enqueue(urls: [downloadTestURL(DownloadFixture.playlistURL)])
        let token = try #require(outcome.pendingPlaylist?.token)
        _ = await harness.service.confirmPlaylist(token)
        await harness.waitUntil { harness.recorder.latestSnapshot.pendingItems.first?.title != nil }

        let expectedThumbnail = try Self.thumbnail()
        let row = try #require(harness.recorder.latestSnapshot.pendingItems.first)
        #expect(row.title == Self.pasteTitle)
        #expect(row.uploader == flatChannel)
        #expect(row.thumbnailURL == expectedThumbnail)
    }

    /// A late answer for a row that has departed writes NOTHING — and in particular
    /// does not land on whichever row inherited its position.
    ///
    /// Two rows are pasted and the FIRST is removed while its own lookup is still in
    /// flight. Only the first has an answer armed, so if the write were addressed by
    /// position rather than by id the surviving row would come back wearing the removed
    /// row's title. The snapshot count is sampled at the removal so a resurrection
    /// would also show up as an extra publication.
    @Test func aLateAnswerForARemovedRowNeverLandsOnItsSuccessor() async throws {
        let oEmbed = try Self.fetcher(latency: .milliseconds(120))
        let harness = DownloadQueueHarness(oEmbed: oEmbed)
        harness.service.pause()

        _ = try await harness.service.enqueue(urls: [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ])
        let removed = try #require(harness.recorder.latestSnapshot.pendingItems.first?.id)
        let survivor = try #require(harness.recorder.latestSnapshot.pendingItems.last?.id)
        harness.service.removePending(removed)
        let publicationsAtRemoval = harness.recorder.snapshots.count

        await harness.waitUntil { oEmbed.fetchCallCount == 2 }
        try await Task.sleep(for: .milliseconds(400))

        let snapshot = harness.recorder.latestSnapshot
        #expect(snapshot.pendingItems.map(\.id) == [survivor])
        #expect(snapshot.pendingItems.first?.title == nil)
        #expect(snapshot.pendingItems.first?.displayTitle == DownloadFixture.otherVideoID)
        #expect(harness.recorder.snapshots.count == publicationsAtRemoval)
    }

    // MARK: (b) Playlists

    /// A playlist expansion is already titled by the listing that expanded it, so it
    /// costs exactly zero lookups no matter how many entries it holds.
    ///
    /// The sleep before the count assertion is LOAD-BEARING, not caution. A decoration
    /// is a `Task`, so it is scheduled on the main actor and has not run by the time
    /// `confirmPlaylist(_:)` returns — reading the counter on that same turn measures a
    /// lookup that has not had a chance to happen yet and reports zero whatever the
    /// implementation does. Measured: without the sleep this test passes against a
    /// decoration that fires for every confirmed row.
    @Test func playlistEntriesArriveTitledAndCostNoLookups() async throws {
        let ids = [DownloadFixture.videoID, DownloadFixture.otherVideoID, DownloadFixture.thirdVideoID]
        let oEmbed = try Self.fetcher()
        let harness = DownloadQueueHarness(
            scripts: [.success(stdout: [DownloadFixture.playlist(ids: ids)])],
            oEmbed: oEmbed
        )
        harness.service.pause()

        let outcome = try await harness.service.enqueue(urls: [downloadTestURL(DownloadFixture.playlistURL)])
        let token = try #require(outcome.pendingPlaylist?.token)
        let confirmed = await harness.service.confirmPlaylist(token)
        try await Task.sleep(for: .milliseconds(80))

        #expect(confirmed.added == ids.count)
        #expect(harness.recorder.latestSnapshot.pendingItems.map(\.title) == ids.map { "Track \($0)" })
        #expect(oEmbed.fetchCallCount == 0)
    }

    // MARK: (c) `-J` authority

    /// `-J` wins where it answers: the engine's title replaces the pasted one outright.
    @Test func dequeueMetadataOverwritesThePasteTimeTitle() async throws {
        let harness = try DownloadQueueHarness(
            scripts: [
                .success(stdout: [DownloadFixture.info(title: "Engine Title", uploader: "Engine Channel")]),
                DownloadFixture.happyDownloadScript,
            ],
            oEmbed: Self.fetcher()
        )
        let finished = try await Self.runOnePausedPaste(harness)

        #expect(finished.item.title == "Engine Title")
        #expect(finished.item.uploader == "Engine Channel")
    }

    /// `-J` does NOT win where it said nothing: a payload with no title leaves the
    /// pasted one standing rather than blanking the row mid-download.
    ///
    /// `durationSeconds` is asserted alongside it because it is what separates "the
    /// rule held" from "enrichment never ran at all" — the same document that omits the
    /// title carries a duration, so a passing test proves the payload really was
    /// applied to this row.
    @Test func dequeueMetadataWithoutATitleLeavesThePasteTimeTitleStanding() async throws {
        let titleless = """
        {"id":"\(DownloadFixture.videoID)","duration":213,\
        "thumbnail":"https://i.ytimg.com/vi/\(DownloadFixture.videoID)/engine.jpg"}
        """
        let harness = try DownloadQueueHarness(
            scripts: [.success(stdout: [titleless]), DownloadFixture.happyDownloadScript],
            oEmbed: Self.fetcher()
        )
        let finished = try await Self.runOnePausedPaste(harness)

        #expect(finished.item.title == Self.pasteTitle)
        #expect(finished.item.uploader == Self.pasteChannel)
        #expect(finished.item.durationSeconds == 213)
        #expect(finished.item.thumbnailURL?.lastPathComponent == "engine.jpg")
    }

    /// An empty title is not an answer either — it would blank the row's label, because
    /// ``DownloadItem/displayTitle`` falls back to the canonical id only for `nil`.
    @Test func dequeueMetadataWithAnEmptyTitleLeavesThePasteTimeTitleStanding() async throws {
        let harness = try DownloadQueueHarness(
            scripts: [
                .success(stdout: [DownloadFixture.info(title: "", uploader: "")]),
                DownloadFixture.happyDownloadScript,
            ],
            oEmbed: Self.fetcher()
        )
        let finished = try await Self.runOnePausedPaste(harness)

        #expect(finished.item.title == Self.pasteTitle)
        #expect(finished.item.uploader == Self.pasteChannel)
    }

    /// Pastes one single into a paused queue, waits for the decoration to land, then
    /// resumes and returns the finished row.
    ///
    /// Waiting for the pasted title BEFORE resuming is what makes the three `-J`
    /// authority tests above statements about an overwrite: without it the row could
    /// reach the driver undecorated and every one of them would pass vacuously.
    private static func runOnePausedPaste(_ harness: DownloadQueueHarness) async throws -> DownloadFinishedEvent {
        harness.service.pause()
        _ = try await harness.service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        await harness.waitUntil { harness.recorder.latestSnapshot.pendingItems.first?.title != nil }
        #expect(harness.recorder.latestSnapshot.pendingItems.first?.title == pasteTitle)

        harness.service.resume()
        await harness.waitForTerminals(1)
        return try #require(harness.recorder.finished.first)
    }
}
