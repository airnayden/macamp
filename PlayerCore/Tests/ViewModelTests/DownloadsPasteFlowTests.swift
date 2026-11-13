import Foundation
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

/// Todo 12 acceptance: the paste sheet's data path — free text becomes links plus a
/// list of refused lines, one paste reports its counts and its held playlist at the
/// same time, and a CAPPED playlist reports the real (truncated) count so the sheet can
/// offer "Add first N" instead of truncating silently.
@MainActor
struct DownloadsPasteFlowTests {
    private static let firstVideo = "dQw4w9WgXcQ"
    private static let secondVideo = "9bZkp7q19f0"
    private static let playlistLink = "https://www.youtube.com/playlist?list=PLabcdefghijk"

    private static func watchLine(_ videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }

    /// 501 distinct 11-character ids — one past the expansion cap, so the queue must
    /// report `capped` and hold exactly `maxPlaylistExpansion` entries.
    private static func overCapIDs() -> [String] {
        (0 ... DownloadQueueLimits.maxPlaylistExpansion).map { String(format: "v%010d", $0) }
    }

    // MARK: Parsing

    @Test func parseAcceptsEveryYouTubeFamilyAndRefusesTheRest() {
        let input = DownloadPasteInput.parse(
            """
            \(Self.watchLine(Self.firstVideo))
            https://youtu.be/\(Self.secondVideo)
            https://www.youtube.com/shorts/\(Self.firstVideo)
            https://music.youtube.com/watch?v=\(Self.secondVideo)

            just some words
            https://vimeo.com/12345
            """
        )

        #expect(input.urls.count == 4)
        #expect(input.skippedLines == ["just some words", "https://vimeo.com/12345"])
        #expect(!input.isEmpty)
    }

    /// A YouTube URL that names NEITHER a video nor a playlist is refused here rather
    /// than handed on: the queue would ignore it silently, which is precisely what the
    /// skipped list exists to prevent.
    @Test func parseRefusesYouTubeURLsThatNameNothing() {
        let input = DownloadPasteInput.parse(
            """
            https://www.youtube.com/@somechannel
            https://www.youtube.com/watch?v=tooshort
            """
        )

        #expect(input.urls.isEmpty)
        #expect(input.skippedLines.count == 2)
    }

    @Test func parseIgnoresBlankLinesAndSurroundingWhitespace() {
        let input = DownloadPasteInput.parse("\n\n   \(Self.watchLine(Self.firstVideo))   \n\n")

        #expect(input.urls.count == 1)
        #expect(input.skippedLines.isEmpty)
    }

    @Test func parseOfNothingIsEmpty() {
        #expect(DownloadPasteInput.parse("   \n  \n").isEmpty)
        #expect(DownloadPasteInput.parse("").urls.isEmpty)
    }

    // MARK: Paste report

    /// QA scenario (happy path): three links, one of them a repeat — the report reads
    /// "3 links, 1 duplicate skipped" and exactly two rows appear.
    @Test func submitReportsAddedAndDuplicatesFromOnePaste() async {
        let harness = DownloadsViewModelHarness()
        let result = await harness.model.submit(pastedText: """
        \(Self.watchLine(Self.firstVideo))
        \(Self.watchLine(Self.secondVideo))
        \(Self.watchLine(Self.firstVideo))
        """)

        #expect(result.linkCount == 3)
        #expect(result.report.added == 2)
        #expect(result.report.duplicatesDropped == 1)
        #expect(result.skippedLines.isEmpty)
        #expect(!result.report.needsConfirmation)
        #expect(harness.model.count == 2)
    }

    /// QA scenario (failure path): a block of garbage enqueues nothing, lists every
    /// refused line, and never reaches the queue at all.
    @Test func submitOfGarbageEnqueuesNothingAndListsEveryLine() async {
        let harness = DownloadsViewModelHarness()
        let result = await harness.model.submit(pastedText: "hello\nthere\nnot a link")

        #expect(result.linkCount == 0)
        #expect(result.report == .zero)
        #expect(result.skippedLines == ["hello", "there", "not a link"])
        #expect(harness.model.isEmpty)
        #expect(harness.queue.enqueuedURLs.isEmpty)
        #expect(!result.isEmpty)
    }

    @Test func submitCarriesCountsSkippedLinesAndAHeldPlaylistTogether() async throws {
        let harness = DownloadsViewModelHarness()
        let playlist = try #require(URL(string: Self.playlistLink))
        harness.queue.playlistExpansion[playlist] = ["aaaaaaaaaaa", "bbbbbbbbbbb"]

        let result = await harness.model.submit(pastedText: """
        \(Self.watchLine(Self.firstVideo))
        \(Self.playlistLink)
        nonsense
        """)

        #expect(result.linkCount == 2)
        #expect(result.report.added == 1)
        #expect(result.skippedLines == ["nonsense"])
        #expect(result.report.pendingPlaylist?.count == 2)
        #expect(result.report.pendingPlaylist?.capped == false)
    }

    // MARK: Capped playlist confirmation

    @Test func overCapPlaylistReportsTheCappedCountRatherThanTruncatingSilently() async throws {
        let harness = DownloadsViewModelHarness()
        let playlist = try #require(URL(string: Self.playlistLink))
        harness.queue.playlistExpansion[playlist] = Self.overCapIDs()

        let result = await harness.model.submit(pastedText: Self.playlistLink)
        let held = try #require(result.report.pendingPlaylist)

        #expect(held.capped)
        #expect(held.count == DownloadQueueLimits.maxPlaylistExpansion)
        #expect(result.report.added == 0)
        #expect(harness.model.isEmpty)
    }

    @Test func confirmingACappedPlaylistQueuesExactlyTheCap() async throws {
        let harness = DownloadsViewModelHarness()
        let playlist = try #require(URL(string: Self.playlistLink))
        harness.queue.playlistExpansion[playlist] = Self.overCapIDs()

        let result = await harness.model.submit(pastedText: Self.playlistLink)
        let token = try #require(result.report.pendingPlaylist?.token)
        let confirmed = await harness.model.confirmPlaylist(token)

        #expect(confirmed.added == DownloadQueueLimits.maxPlaylistExpansion)
        #expect(harness.model.count == DownloadQueueLimits.maxPlaylistExpansion)
        #expect(harness.queue.confirmedTokens == [token])
    }

    /// A token the queue has already consumed answers with the zero outcome, which the
    /// sheet renders as "0 added" — an expired confirmation is not an error.
    @Test func confirmingTheSameCappedPlaylistTwiceReportsZeroTheSecondTime() async throws {
        let harness = DownloadsViewModelHarness()
        let playlist = try #require(URL(string: Self.playlistLink))
        harness.queue.playlistExpansion[playlist] = Self.overCapIDs()

        let result = await harness.model.submit(pastedText: Self.playlistLink)
        let token = try #require(result.report.pendingPlaylist?.token)
        _ = await harness.model.confirmPlaylist(token)
        let replay = await harness.model.confirmPlaylist(token)

        #expect(replay == .zero)
        #expect(replay.isEmpty)
        #expect(harness.model.count == DownloadQueueLimits.maxPlaylistExpansion)
    }
}
