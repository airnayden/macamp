// What happens to a REGISTERED chat download that never produces a file — driven end to
// end through ``FakeDownloadQueue``'s own `onItemProgress` seam.
//
// ── ZERO SCANS IS THE RECOVERY CONTRACT ──────────────────────────────────────
//
// Recovery appends from a path the download history already recorded. Nothing new landed
// on disk, so rescanning would be filesystem work for its own sake. Every recovery test
// asserts `scanLog.count == 0` through the COUNTING scanner the appender fixture owns —
// a count, not a log line, because "how many times did you scan" is the question.
//
// ── THE TWO UNRESOLVED BRANCHES MUST DIFFER ──────────────────────────────────
//
// `exitOutcome` maps every `ExitCode.downloadError` to `.downloadFailed` — network errors
// and 403s included — so an unresolved history lookup after `.downloadFailed` is a plain
// failure and must announce the GENERIC `.appendAbandoned`. `.alreadyDownloadedUnresolved`
// is reserved for the shape that actually said "already downloaded". Both branches land in
// the same appender method, which is exactly why the event is injected rather than
// inferred, and why both are pinned here.
//
// Announcements are asserted as whole ordered arrays, so an EXTRA event fails too: a
// handler that announced once per fanned-out registration would pass a `contains` check.
import Foundation
import Persistence
import Services
import Testing

@Suite(.serialized)
@MainActor
struct ChatDownloadTerminalStateTests {
    /// `.failed(.alreadyDownloaded)`: the engine skipped the work because the file was
    /// already in the destination. History knows where it went, the library already has
    /// the row, and the append happens with no scan at all.
    @Test("alreadyDownloaded recovers through history and appends with zero scans")
    func alreadyDownloadedRecoversFromHistory() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let imported = try fixture.importedFilePath()
        try await fixture.recordHistory(videoID: ChatTerminalFixtureIDs.first, filePath: imported.path)
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .failed(.alreadyDownloaded))

        #expect(try await fixture.membership(playlistId: playlistId) == [imported.trackId])
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
        #expect(fixture.announcements.events == [
            .appended(playlistId: playlistId, trackId: imported.trackId),
        ])
    }

    /// `.failed(.downloadFailed)`: the SKILL's recorded re-download shape — yt-dlp exits
    /// on the stream-copy path with `ERROR: Postprocessing: Conversion failed!` rather
    /// than reporting the file as already downloaded. It must recover identically.
    @Test("downloadFailed recovers through history and appends with zero scans")
    func downloadFailedRecoversFromHistory() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let imported = try fixture.importedFilePath()
        try await fixture.recordHistory(videoID: ChatTerminalFixtureIDs.first, filePath: imported.path)
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(
            item,
            state: .failed(.downloadFailed(detail: "ERROR: Postprocessing: Conversion failed!"))
        )

        #expect(try await fixture.membership(playlistId: playlistId) == [imported.trackId])
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
        #expect(fixture.announcements.events == [
            .appended(playlistId: playlistId, trackId: imported.trackId),
        ])
    }

    /// A history row exists but names a file that is not a library row, so the lookup
    /// resolves nothing. The `.alreadyDownloaded` shape says so specifically.
    @Test("alreadyDownloaded with an unresolvable history path announces alreadyDownloadedUnresolved")
    func alreadyDownloadedUnresolvedAnnouncesItsOwnEvent() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let orphan = fixture.destination.appendingPathComponent("Never imported.m4a").path
        try await fixture.recordHistory(videoID: ChatTerminalFixtureIDs.first, filePath: orphan)
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .failed(.alreadyDownloaded))

        #expect(try await fixture.membership(playlistId: playlistId).isEmpty)
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
        #expect(fixture.announcements.events == [.alreadyDownloadedUnresolved])
    }

    /// No history row at all after a plain transfer failure: the generic notice, NEVER
    /// the already-downloaded one. A network error is not a re-download.
    @Test("downloadFailed with no history row announces the generic appendAbandoned")
    func downloadFailedWithoutHistoryAnnouncesAbandoned() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .failed(.downloadFailed(detail: "HTTP Error 403: Forbidden")))

        #expect(try await fixture.membership(playlistId: playlistId).isEmpty)
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
        #expect(fixture.announcements.events == [.appendAbandoned])
    }

    /// A plain fault with TWO targets waiting: exactly ONE notice, not one per
    /// registration. The listener abandoned one download, not two.
    @Test("a plain failure evicts every target and announces exactly one appendAbandoned")
    func plainFailureAnnouncesOnceForTheWholeFanOut() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makePlaylist(named: "One")
        let second = try fixture.makePlaylist(named: "Two")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: first))
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: second))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .failed(.destinationUnavailable))

        #expect(fixture.announcements.events == [.appendAbandoned])
        #expect(fixture.registry.count == 0)
        #expect(fixture.scanLog.count == 0)
        #expect(try await fixture.membership(playlistId: first).isEmpty)
        #expect(try await fixture.membership(playlistId: second).isEmpty)
        #expect(fixture.map.count == 0)
    }

    /// The bare `.cancelled` — the shape the seam actually publishes in production,
    /// because `applyOutcome` rewrites the failure before `settle` publishes it. The
    /// person chose this, so there is nothing to tell them.
    @Test("a bare cancelled evicts the registration with no announcement at all")
    func bareCancelEvictsSilently() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .cancelled)

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 0)
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.map.count == 0)
    }

    /// The `.failed(.cancelled)` shape — `run()`'s internal outcome, which would reach
    /// the seam if the driver's rewrite ever narrowed. Driven DIRECTLY, because
    /// `FakeDownloadQueue.cancel` only ever emits the bare case and this one would
    /// regress unseen behind it.
    @Test("a failed(.cancelled) evicts just as silently as the bare shape")
    func failedCancelEvictsSilently() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .failed(.cancelled))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 0)
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.map.count == 0)
    }

    /// A cancel for a download nobody registered: the handler resolves the video id,
    /// finds nothing waiting, and leaves an UNRELATED registration alone.
    @Test("cancelling an unregistered download disturbs no other registration")
    func cancellingAnUnregisteredDownloadIsANoOp() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let stranger = try await fixture.startDownload(ChatTerminalFixtureIDs.second)

        await fixture.finish(stranger, state: .cancelled)

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 1)
        #expect(fixture.map.count == 0)
    }

    /// A NOTICE-worthy failure for a download nobody registered announces nothing: there
    /// is no abandoned append expectation to report, and the queue row renders its own
    /// error copy already.
    @Test("a plain failure on an unregistered download announces nothing")
    func plainFailureOnUnregisteredDownloadAnnouncesNothing() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let stranger = try await fixture.startDownload(ChatTerminalFixtureIDs.second)

        await fixture.finish(stranger, state: .failed(.toolMissing))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 1)
        #expect(fixture.map.count == 0)
    }

    /// The recovery branch with nothing waiting: no history read is worth doing and no
    /// append can happen, but the correlation still has to be released.
    @Test("an unregistered alreadyDownloaded prunes the map and announces nothing")
    func unregisteredRecoveryStillPrunes() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let imported = try fixture.importedFilePath()
        try await fixture.recordHistory(videoID: ChatTerminalFixtureIDs.second, filePath: imported.path)
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.second)

        await fixture.finish(item, state: .failed(.alreadyDownloaded))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.scanLog.count == 0)
        #expect(fixture.map.count == 0)
    }
}
