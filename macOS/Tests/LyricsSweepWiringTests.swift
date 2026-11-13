// LyricsSweepWiringTests — the sweep's refresh signal is really attached.
//
// `LyricsSweepTests` (PlayerCore) proves the pass emits `onDidCacheLyrics`, and
// `LyricsBrowserViewModelTests` proves `cacheDidChange()` reloads the window. What
// neither can prove is that the composition root ever CONNECTS the two — and an
// unconnected signal fails silently: the sweep fills `lyricsCache` correctly while
// the Lyrics list sits empty for the whole session, which is exactly how this bug
// was reported. This suite closes that gap from the shell side, and lives in the
// app test target because `AppEnvironment` is not part of the package.
import Foundation
import Lyrics
@testable import MacAMP
import Persistence
import Testing
import ViewModels

@Suite("Lyrics sweep wiring")
@MainActor
struct LyricsSweepWiringTests {
    private static let sweptPath = "/music/swept.flac"

    @Test("building the environment connects the sweep to the lyrics browser")
    func launchWiringConnectsTheRefreshSignal() async throws {
        let environment = AppEnvironment.preview()
        try await environment.lyricsBrowser.loadInitial()
        #expect(environment.lyricsBrowser.totalCount == 0)

        let signal = try #require(environment.lyricsSweep.onDidCacheLyrics)
        try seedSweptTrack(environment.database)
        signal()
        await drainRefresh(environment.lyricsBrowser)

        #expect(environment.lyricsBrowser.totalCount == 1)
        #expect(environment.lyricsBrowser.tracks.map(\.filePath) == [Self.sweptPath])
    }

    /// Stands in for one probe of the offline sweep: a present track plus the
    /// document the pass would have cached under its path.
    private func seedSweptTrack(_ database: AppDatabase) throws {
        _ = try TrackRepository(database).insert(
            TrackRecord(filePath: Self.sweptPath, title: "Swept", sortTitle: "swept")
        )
        try GRDBLyricsCache(database).store(
            Lyrics(lines: [LyricLine(text: "la la la")], source: .embeddedUnsynced),
            forKey: Self.sweptPath
        )
    }

    /// The wiring hops to the main actor before it reaches the browser, so the
    /// reload cannot be awaited directly — poll the hop, then await the reload.
    private func drainRefresh(_ browser: LyricsBrowserViewModel) async {
        for _ in 0 ..< 200 {
            await browser.waitForPendingRefresh()
            if browser.totalCount > 0 { return }
            await Task.yield()
        }
    }
}
