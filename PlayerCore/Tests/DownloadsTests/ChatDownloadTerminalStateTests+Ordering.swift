// The locks that are about ORDER and about doing nothing — the two ways this seam can
// fail without any test above noticing.
//
// ── WHY ORDERING NEEDS ITS OWN TEST ──────────────────────────────────────────
//
// `settle(_:)` publishes the terminal `onItemProgress` BEFORE the post-removal snapshot,
// so a map that mirrored each snapshot instead of accumulating would still pass every
// recovery test in the sibling file. The test below inverts that order deliberately — the
// row leaves the queue, its removal snapshot is ingested, and only THEN does the terminal
// state arrive — which is the shape a future change to the driver's internals would
// produce. The mapping must survive it.
//
// ── WHY DOING NOTHING NEEDS ITS OWN TEST ─────────────────────────────────────
//
// `.ignore` is not "no classification yet": `.finished` is deliberately ignored because
// the finished seam owns it, and todo 9's ordering depends on this handler leaving the
// registry AND the map untouched for it. A handler that pruned on `.finished` would strip
// the correlation out from under the seam that still needs it, and every failure test
// would still pass.
import Foundation
import Persistence
import Services
import Testing

extension ChatDownloadTerminalStateTests {
    /// The ordering-independence lock: the removal snapshot arrives BEFORE the terminal
    /// state, and the correlation still resolves.
    @Test("a post-removal snapshot ingested before the terminal state keeps the mapping")
    func removalSnapshotBeforeTerminalKeepsTheMapping() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let imported = try fixture.importedFilePath()
        try await fixture.recordHistory(videoID: ChatTerminalFixtureIDs.first, filePath: imported.path)
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.enqueuePending(ChatTerminalFixtureIDs.first)
        #expect(fixture.map.count == 1)

        fixture.queue.removePending(item.id)
        #expect(fixture.queue.pendingItems.isEmpty)
        await fixture.emit(item.id, state: .failed(.alreadyDownloaded))

        #expect(try await fixture.membership(playlistId: playlistId) == [imported.trackId])
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
        #expect(fixture.announcements.events == [
            .appended(playlistId: playlistId, trackId: imported.trackId),
        ])
    }

    /// An item id the map never learned: the handler returns before touching anything.
    /// The registry is the thing that must not move — an unresolved id evicting "some"
    /// registration would be the worst possible guess.
    @Test("an unknown item id resolves nothing and changes nothing")
    func unknownItemIDIsANoOp() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.emit(UUID(), state: .failed(.destinationUnavailable))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 1)
        #expect(fixture.map.videoID(for: item.id) == ChatTerminalFixtureIDs.first)
        #expect(fixture.map.count == 1)
    }

    /// Mid-flight states leave the registration AND the correlation exactly where they
    /// are — the download has not finished failing yet.
    @Test("non-terminal states leave the registry and the map untouched")
    func nonTerminalStatesTouchNothing() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.emit(item.id, state: .downloading(fraction: 0.5, speedBytesPerSec: 2048, etaSeconds: 12))
        await fixture.emit(item.id, state: .postProcessing(fraction: nil))
        await fixture.emit(item.id, state: .postProcessing(fraction: 0.9))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 1)
        #expect(fixture.map.videoID(for: item.id) == ChatTerminalFixtureIDs.first)
        #expect(fixture.scanLog.count == 0)
    }

    /// `.finished` belongs to the finished seam. This handler must not claim the
    /// registration and must not prune the correlation, or the seam that runs next has
    /// nothing left to work with.
    @Test("a finished state leaves both the registration and the correlation for the finished seam")
    func finishedStateIsLeftToTheFinishedSeam() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let imported = try fixture.importedFilePath()
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.finish(item, state: .finished(fileURL: URL(fileURLWithPath: imported.path)))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 1)
        #expect(fixture.map.videoID(for: item.id) == ChatTerminalFixtureIDs.first)
        #expect(fixture.map.count == 1)
        #expect(fixture.scanLog.count == 0)
        #expect(try await fixture.membership(playlistId: playlistId).isEmpty)
    }

    /// A terminal state emitted twice for one row. The claim is destructive, so the
    /// second pass finds nothing waiting and announces nothing — one abandoned download
    /// is one notice however many times the seam repeats itself.
    @Test("a repeated terminal state announces exactly once")
    func repeatedTerminalStateAnnouncesOnce() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let item = try await fixture.startDownload(ChatTerminalFixtureIDs.first)

        await fixture.emit(item.id, state: .failed(.invalidArguments))
        await fixture.emit(item.id, state: .failed(.invalidArguments))

        #expect(fixture.announcements.events == [.appendAbandoned])
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
    }

    /// Two rows in flight, one registered and one not: the terminal state of the
    /// unregistered row must resolve to ITS OWN video id and leave the other alone.
    @Test("concurrent rows resolve to their own video ids")
    func concurrentRowsResolveIndependently() async throws {
        let fixture = try ChatTerminalFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        #expect(fixture.register(ChatTerminalFixtureIDs.first, playlistId: playlistId))
        let registered = try await fixture.startDownload(ChatTerminalFixtureIDs.first)
        let stranger = try await fixture.startDownload(ChatTerminalFixtureIDs.second)
        #expect(fixture.map.count == 2)

        await fixture.finish(stranger, state: .failed(.engineRestartRequired))

        #expect(fixture.announcements.events.isEmpty)
        #expect(fixture.registry.count == 1)
        #expect(fixture.map.videoID(for: registered.id) == ChatTerminalFixtureIDs.first)
        #expect(fixture.map.count == 1)

        await fixture.finish(registered, state: .failed(.engineRestartRequired))

        #expect(fixture.announcements.events == [.appendAbandoned])
        #expect(fixture.registry.count == 0)
        #expect(fixture.map.count == 0)
    }
}
