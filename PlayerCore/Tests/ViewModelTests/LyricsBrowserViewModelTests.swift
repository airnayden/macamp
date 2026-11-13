// LyricsBrowserViewModelTests — the lyrics browse window plus the preview seam.
//
// The load-bearing assertion here is isolation: previewing a track must resolve
// through the browser's OWN `LyricsViewModel`, leaving the now-playing model and
// its provider completely untouched.
import Foundation
import Lyrics
import Persistence
import Services
import Testing
@testable import ViewModels

@MainActor
struct LyricsBrowserViewModelTests {
    private func rows(_ count: Int) -> [LyricsRowDTO] {
        (0 ..< count).map { index in
            LyricsRowDTO(
                trackId: Int64(index + 1),
                filePath: "/M/track\(index).flac",
                title: String(format: "Track %02d", index),
                artist: "Artist",
                duration: 100,
                isSynced: index.isMultiple(of: 2)
            )
        }
    }

    private func syncedLyrics() -> Lyrics {
        Lyrics(lines: [LyricLine(time: 0, text: "one"), LyricLine(time: 2, text: "two")], source: .lrcFile)
    }

    private func makeModel(
        browser: FakeLyricsBrowser,
        provider: any LyricsProviding = FakeLyricsProvider(),
        pageSize: Int = 100,
        activeProfileId: Int64 = ProfileRecord.guestID
    ) -> LyricsBrowserViewModel {
        LyricsBrowserViewModel(
            repository: browser,
            provider: provider,
            pageSize: pageSize,
            activeProfileId: activeProfileId,
            refreshDebounce: .zero
        )
    }

    // MARK: - Refresh on cache writes

    /// The launch sweep commits rows long after this list has loaded, and the view
    /// only re-reads on re-mount — so a browser that ignores later writes shows an
    /// empty list all session and lyrics seem to appear only when a song is played.
    @Test func cacheDidChangeReloadsRowsWrittenAfterTheInitialLoad() async throws {
        let browser = FakeLyricsBrowser(rows: [])
        let model = makeModel(browser: browser)
        try await model.loadInitial()
        #expect(model.tracks.isEmpty)
        #expect(model.totalCount == 0)

        browser.setRows(rows(3))
        model.cacheDidChange()
        await model.waitForPendingRefresh()

        #expect(model.tracks.map(\.title) == ["Track 00", "Track 01", "Track 02"])
        #expect(model.totalCount == 3)
    }

    @Test func cacheDidChangeCoalescesABurstIntoTheLatestWindow() async throws {
        let browser = FakeLyricsBrowser(rows: [])
        let model = makeModel(browser: browser)
        try await model.loadInitial()

        browser.setRows(rows(1))
        model.cacheDidChange()
        browser.setRows(rows(4))
        model.cacheDidChange()
        await model.waitForPendingRefresh()

        #expect(model.tracks.count == 4)
        #expect(model.totalCount == 4)
    }

    @Test func cacheDidChangeKeepsTheWindowScopedToTheActiveProfile() async throws {
        let browser = FakeLyricsBrowser(rowsByProfile: [:])
        let model = makeModel(browser: browser, activeProfileId: 7)
        try await model.loadInitial()

        browser.setRows(rows(2), profileId: ProfileRecord.guestID)
        browser.setRows(rows(1), profileId: 7)
        model.cacheDidChange()
        await model.waitForPendingRefresh()

        #expect(model.tracks.count == 1)
        #expect(model.totalCount == 1)
    }

    // MARK: - Paging

    @Test func loadInitialFillsTheWindowAndTheTotalCount() async throws {
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(3)))

        try await model.loadInitial()

        #expect(model.tracks.map(\.title) == ["Track 00", "Track 01", "Track 02"])
        #expect(model.totalCount == 3)
        #expect(!model.hasMore)
        #expect(!model.isLoading)
    }

    @Test func pagesGrowTheWindowWithoutDuplicates() async throws {
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(5)), pageSize: 2)

        try await model.loadInitial()
        #expect(model.tracks.count == 2)
        #expect(model.hasMore)

        try await model.loadMore()
        try await model.loadMore()

        #expect(model.tracks.map(\.trackId) == [1, 2, 3, 4, 5])
        #expect(model.totalCount == 5)
        #expect(!model.hasMore)
    }

    @Test func loadMoreIsANoOpOnceExhausted() async throws {
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(2)), pageSize: 5)

        try await model.loadInitial()
        try await model.loadMore()

        #expect(model.tracks.count == 2)
    }

    @Test func emptyLibraryReportsZeroCountAndNoMorePages() async throws {
        let model = makeModel(browser: FakeLyricsBrowser(rows: []))

        try await model.loadInitial()

        #expect(model.tracks.isEmpty)
        #expect(model.totalCount == 0)
        #expect(!model.hasMore)
    }

    // MARK: - Profile scoping

    @Test func rescopingToAnotherProfileReloadsThatProfilesRows() async throws {
        let other: Int64 = 7
        let browser = FakeLyricsBrowser(rowsByProfile: [
            ProfileRecord.guestID: rows(2),
            other: [LyricsRowDTO(trackId: 99, filePath: "/Other/x.flac", title: "Zulu")],
        ])
        let model = makeModel(browser: browser)

        try await model.loadInitial()
        #expect(model.tracks.count == 2)

        model.activeProfileId = other
        try await model.loadInitial()

        #expect(model.tracks.map(\.title) == ["Zulu"])
        #expect(model.totalCount == 1)
    }

    // MARK: - Preview isolation

    @Test func selectResolvesThroughThePreviewModelAndNeverTheNowPlayingOne() async {
        let previewProvider = FakeLyricsProvider(returning: syncedLyrics())
        let nowPlayingProvider = FakeLyricsProvider(returning: syncedLyrics())
        let nowPlaying = LyricsViewModel(provider: nowPlayingProvider)
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(1)), provider: previewProvider)

        model.select(rows(1)[0].trackRef, options: .offline)
        await pollUntil { model.previewLyrics.lyrics != nil }

        #expect(model.previewLyrics.lines.count == 2)
        #expect(previewProvider.requests.count == 1)
        #expect(nowPlayingProvider.requests.isEmpty)
        #expect(nowPlaying.lyrics == nil)
        #expect(nowPlaying.lines.isEmpty)
    }

    @Test func sharingOneProviderStillLeavesTheNowPlayingModelUntouched() async {
        let provider = FakeLyricsProvider(returning: syncedLyrics())
        let nowPlaying = LyricsViewModel(provider: provider)
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(1)), provider: provider)

        model.select(rows(1)[0].trackRef)
        await pollUntil { model.previewLyrics.lyrics != nil }

        #expect(provider.requests.count == 1)
        #expect(nowPlaying.lyrics == nil)
        #expect(nowPlaying.isLoading == false)
    }

    @Test func selectBuildsTheSameRequestShapeAsTheNowPlayingPanel() async throws {
        let provider = FakeLyricsProvider(returning: syncedLyrics())
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(1)), provider: provider)
        let row = rows(1)[0]

        model.select(row.trackRef, options: .offline)
        await pollUntil { model.previewLyrics.lyrics != nil }

        let recorded = provider.requests
        let request = try #require(recorded.first)
        #expect(request.trackURL == URL(fileURLWithPath: row.filePath))
        #expect(request.title == row.title)
        #expect(request.artist == row.artist)
        #expect(request.album == nil)
        #expect(request.duration == row.duration)
        #expect(request.cacheKey == row.filePath)
    }

    @Test func clearPreviewResetsBothTheSelectionAndTheResolvedDocument() async {
        let provider = FakeLyricsProvider(returning: syncedLyrics())
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(1)), provider: provider)

        model.select(rows(1)[0].trackRef)
        await pollUntil { model.previewLyrics.lyrics != nil }
        #expect(model.previewTrack != nil)

        model.clearPreview()

        #expect(model.previewTrack == nil)
        #expect(model.previewLyrics.lyrics == nil)
        #expect(model.previewLyrics.lines.isEmpty)
        #expect(!model.previewLyrics.isLoading)
    }

    @Test func previewingASecondTrackReplacesTheFirst() async {
        let provider = FakeLyricsProvider(returning: syncedLyrics())
        let model = makeModel(browser: FakeLyricsBrowser(rows: rows(2)), provider: provider)
        let pair = rows(2)

        model.select(pair[0].trackRef)
        await pollUntil { model.previewLyrics.lyrics != nil }
        model.select(pair[1].trackRef)
        await pollUntil { provider.requests.count == 2 }

        #expect(model.previewTrack?.filePath == pair[1].filePath)
        #expect(provider.requests.map(\.title) == ["Track 00", "Track 01"])
    }

    @Test func trackRefCarriesTheRowIdentityAndPresentAvailability() {
        let row = rows(1)[0]

        let ref = row.trackRef

        #expect(ref.trackID == row.trackId)
        #expect(ref.filePath == row.filePath)
        #expect(ref.title == row.title)
        #expect(ref.artist == row.artist)
        #expect(ref.duration == row.duration)
        #expect(ref.availability == .present)
        #expect(ref.isPlayable)
    }
}
