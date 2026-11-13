// The finish-side pipeline, driven over a real database: gate → exactly ONE scan →
// lookup → append-or-hold.
//
// Two locks carry the suite. The FIRST is that a scan reporting `skipped: 1, added: 0`
// is a SUCCESS: the common case is that the file was already imported by the ordinary
// auto-import path or the folder watcher a moment earlier, and a pipeline that treated
// the summary as its success condition would silently drop exactly the appends that were
// working. Only a real scanner can prove that, so one test runs one.
//
// The SECOND is that exactly one scan happens per finished item however many targets are
// waiting on it, and none at all when the gate refuses — asserted with a COUNTING
// scanner rather than by reading a log line, because "how many times did you scan" is
// the question and a count is the only honest answer to it.
//
// Announcements are asserted as whole ordered arrays wherever the expected set is small,
// so an EXTRA event is a failure too. A pipeline that announced both `.gateFailed` and
// `.importFailed` for one refused file would pass a `contains` assertion.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite(.serialized)
@MainActor
struct ChatDownloadPlaylistAppenderTests {
    /// (a) The skipped-scan success lock.
    ///
    /// The file is imported ONCE up front through the inner scanner directly — which the
    /// counting wrapper never sees — so the pipeline's own scan can only report
    /// `skipped: 1, added: 0`. The append must still happen. This is the case a
    /// `guard summary.added > 0` would break, and it is the common one in production.
    @Test("a scan that skips an already-imported file still appends the track")
    func skippedScanStillAppends() async throws {
        let fixture = try ChatDownloadAppenderFixture(scannerMode: .real)
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let preImport = await fixture.scanner.inner?.scan(.files([file]))
        #expect(preImport == ScanSummary(added: 1))
        let playlistId = try fixture.makePlaylist(named: "Chat picks")

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.playlist(playlistId))]
        )

        #expect(fixture.scanLog.records.map(\.summary) == [ScanSummary(skipped: 1)])
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids.count == 1)
        #expect(fixture.announcements.events.count == 1)
    }

    /// (b) One scan for two waiting targets.
    ///
    /// Two playlists are registered against one download. A per-registration scan would
    /// count two, and at the documented library scale that multiplication is the
    /// difference between one file import and a fan-out of them.
    @Test("two waiting targets share exactly one scan and both receive the track")
    func twoTargetsShareOneScan() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let trackId = try fixture.insertTrack(at: file.path)
        let first = try fixture.makePlaylist(named: "One")
        let second = try fixture.makePlaylist(named: "Two")

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.playlist(first)), fixture.registration(.playlist(second))]
        )

        #expect(fixture.scanLog.count == 1)
        #expect(fixture.scanLog.records.first?.files == [file])
        let leading = try await fixture.membership(playlistId: first)
        let trailing = try await fixture.membership(playlistId: second)
        #expect(leading == [trackId])
        #expect(trailing == [trackId])
        #expect(fixture.announcements.events == [
            .appended(playlistId: first, trackId: trackId),
            .appended(playlistId: second, trackId: trackId),
        ])
    }

    /// (b, negative) and (c): a refused gate scans NOTHING and imports NOTHING.
    ///
    /// Run against a REAL scanner so "no library row" is a statement about the gate
    /// rather than about a fake that never writes rows anyway. Auto-import is off and
    /// the destination folder is under no library root — the two-answer refusal
    /// ``ChatDownloadImportGate`` documents.
    @Test("a refused gate runs no scan, writes no library row, and announces once")
    func refusedGateNeitherScansNorImports() async throws {
        let fixture = try ChatDownloadAppenderFixture(scannerMode: .real)
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        fixture.gate.set(autoImport: false, roots: [])
        let playlistId = try fixture.makePlaylist(named: "Chat picks")

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.playlist(playlistId))]
        )

        #expect(fixture.scanLog.count == 0)
        let rows = try fixture.libraryRowCount()
        #expect(rows == 0)
        #expect(fixture.announcements.events == [.gateFailed])
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids.isEmpty)
    }

    /// (d) A playlist deleted while its download was in flight.
    ///
    /// The append must not throw out of the seam — a download-completion callback has no
    /// caller that could handle it — and must not be confused with a write failure.
    @Test("a deleted playlist announces playlistMissing and lets nothing throw")
    func deletedPlaylistAnnouncesMissing() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let playlistId = try fixture.makePlaylist(named: "Doomed")
        try fixture.insertTrack(at: file.path)
        let deleted = try await fixture.playlists.deletePlaylist(id: playlistId)
        #expect(deleted)

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.playlist(playlistId))]
        )

        #expect(fixture.announcements.events == [.playlistMissing(playlistId)])
    }

    /// (e) Duplicate suppression, driven through the REAL `containsTrack` read.
    ///
    /// The same download finishing twice for the same playlist is ordinary — a
    /// re-download of a track already in the list. The first call answers `false` and
    /// the second `true`, so both branches of the new repository read are exercised
    /// against real SQL rather than a fake's membership set.
    @Test("a second finish for the same playlist is skipped, not doubled")
    func duplicateMembershipIsSkipped() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let trackId = try fixture.insertTrack(at: file.path)
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let registrations = [fixture.registration(.playlist(playlistId))]

        await fixture.appender.handleFinished(videoID: "v", fileURL: file, registrations: registrations)
        #expect(fixture.announcements.events == [.appended(playlistId: playlistId, trackId: trackId)])
        fixture.announcements.reset()

        await fixture.appender.handleFinished(videoID: "v", fileURL: file, registrations: registrations)

        #expect(fixture.announcements.events == [.alreadyInPlaylist(playlistId: playlistId, trackId: trackId)])
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids == [trackId])
    }

    /// (f) A profile switch between request and completion.
    ///
    /// The registration carries the profile that asked for the download, so an append
    /// under a different active profile would file someone else's track into someone
    /// else's playlist. No scan runs either: with every registration skipped there is
    /// nobody left to import for.
    @Test("a profile switch skips the append and scans nothing")
    func profileSwitchSkipsTheAppend() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        try fixture.insertTrack(at: file.path)
        let playlistId = try fixture.makePlaylist(named: "Guest only")
        fixture.profile.set(ProfileRecord.guestID + 41)

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.playlist(playlistId))]
        )

        #expect(fixture.announcements.events == [.skippedProfileChanged])
        #expect(fixture.scanLog.count == 0)
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids.isEmpty)
    }

    /// (g) The download beat its proposal.
    ///
    /// The playlist has no id yet, so the track id parks on the registry instead of
    /// being dropped. The scan still happens — the file genuinely belongs in the library
    /// whether or not the proposal is ever applied.
    @Test("a pending proposal parks the track id and appends nothing")
    func pendingProposalHoldsTheTrack() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let trackId = try fixture.insertTrack(at: file.path)
        let proposal = UUID()

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.pendingProposal(proposal))]
        )

        #expect(fixture.announcements.events == [.heldForProposal(proposal)])
        #expect(fixture.registry.heldTrackIds(forProposal: proposal) == [trackId])
        #expect(fixture.scanLog.count == 1)
    }

    /// (h) The recovery entry appends from a recorded history path with NO scan.
    ///
    /// The engine reported the video as already downloaded, so there is no new file and
    /// nothing to import — scanning would be a rescan of a row that already exists.
    @Test("recovery appends from a history path without scanning")
    func recoveryAppendsWithoutScanning() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let trackId = try fixture.insertTrack(at: file.path)
        let playlistId = try fixture.makePlaylist(named: "Chat picks")

        await fixture.appender.recoverAlreadyDownloaded(
            videoID: "dQw4w9WgXcQ",
            historyFilePath: file.path,
            registrations: [fixture.registration(.playlist(playlistId))],
            unresolvedEvent: .alreadyDownloadedUnresolved
        )

        #expect(fixture.scanLog.count == 0)
        #expect(fixture.announcements.events == [.appended(playlistId: playlistId, trackId: trackId)])
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids == [trackId])
    }

    /// (h, unresolvable) The injected event is announced VERBATIM, both ways.
    ///
    /// The appender cannot see the failure shape that brought it here, so the caller
    /// chooses the wording: `.alreadyDownloadedUnresolved` for a video the engine had
    /// already fetched, `.appendAbandoned` for one that failed outright. Pinning both
    /// proves the parameter is used rather than a constant being announced.
    @Test("an unresolvable recovery announces exactly the injected event")
    func unresolvableRecoveryAnnouncesTheInjectedEvent() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let registrations = [fixture.registration(.playlist(playlistId))]

        await fixture.appender.recoverAlreadyDownloaded(
            videoID: "dQw4w9WgXcQ",
            historyFilePath: nil,
            registrations: registrations,
            unresolvedEvent: .alreadyDownloadedUnresolved
        )
        #expect(fixture.announcements.events == [.alreadyDownloadedUnresolved])
        fixture.announcements.reset()

        await fixture.appender.recoverAlreadyDownloaded(
            videoID: "dQw4w9WgXcQ",
            historyFilePath: "/nowhere/never-imported.m4a",
            registrations: registrations,
            unresolvedEvent: .appendAbandoned
        )

        #expect(fixture.announcements.events == [.appendAbandoned])
        #expect(fixture.scanLog.count == 0)
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids.isEmpty)
    }

    /// The failure-path lock the QA section names: the scan ran and the row still is not
    /// there.
    ///
    /// Distinct from `.gateFailed` — that one never scanned. This one did, and the file
    /// still is not something the library could read, so there is no track to append.
    @Test("a scan that produces no library row announces importFailed and appends nothing")
    func unresolvedLookupAnnouncesImportFailed() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()
        let playlistId = try fixture.makePlaylist(named: "Chat picks")

        await fixture.appender.handleFinished(
            videoID: "dQw4w9WgXcQ",
            fileURL: file,
            registrations: [fixture.registration(.playlist(playlistId))]
        )

        #expect(fixture.scanLog.count == 1)
        #expect(fixture.announcements.events == [.importFailed])
        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids.isEmpty)
    }

    /// The defensive shape for the contract's "non-empty by construction" claim.
    ///
    /// The caller claims registrations synchronously and only dispatches when the claim
    /// is non-empty, so an empty array should be unreachable. If it arrives anyway there
    /// is nothing to import FOR, so the pipeline must scan nothing and say nothing
    /// rather than import a file on nobody's behalf.
    @Test("an empty registration list scans nothing and announces nothing")
    func emptyRegistrationsDoNothing() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.writeDownloadedFile()

        await fixture.appender.handleFinished(videoID: "v", fileURL: file, registrations: [])

        #expect(fixture.scanLog.count == 0)
        #expect(fixture.announcements.events.isEmpty)
    }

    /// Serialized appends, proven by a HEAD-ON collision rather than by timing.
    ///
    /// Both flushes start with `shared`, so the two appends of it reach their
    /// `containsTrack` read in the same window. Unserialized, both read "not a member"
    /// before either writes and the track lands TWICE — the classic check-then-act race,
    /// and the reason a bare `@MainActor` is not enough (each append suspends at the
    /// existence probe and again at the membership read, and another append runs in
    /// either gap). With the append chain the second waits for the first to finish and
    /// reports `.alreadyInPlaylist`.
    ///
    /// The overlap must sit at the HEAD of both lists. An overlap at unequal offsets —
    /// the third id of one flush against the first of the other — asserts nothing about
    /// serialization: those two appends never reach their membership read in the same
    /// window, so such a test passes whether the chain is there or not.
    ///
    /// `leadingFollower` after `shared` is the ordering half of the same guarantee: a
    /// flush's own ids must land in the order it asked for.
    @Test("concurrent flushes append a contended track exactly once, in per-flush order")
    func concurrentFlushesSerializeAppends() async throws {
        let fixture = try ChatDownloadAppenderFixture()
        defer { fixture.cleanUp() }
        let playlistId = try fixture.makePlaylist(named: "Chat picks")
        let shared = try fixture.insertTrack(at: "/Music/shared.m4a")
        let leadingFollower = try fixture.insertTrack(at: "/Music/leading.m4a")
        let trailingFollower = try fixture.insertTrack(at: "/Music/trailing.m4a")
        let appender = fixture.appender

        async let leading: Void = appender.flushHeldAppends(
            trackIds: [shared, leadingFollower],
            playlistId: playlistId
        )
        async let trailing: Void = appender.flushHeldAppends(
            trackIds: [shared, trailingFollower],
            playlistId: playlistId
        )
        _ = await (leading, trailing)

        let ids = try await fixture.membership(playlistId: playlistId)
        #expect(ids.count == 3)
        #expect(Set(ids) == Set([shared, leadingFollower, trailingFollower]))
        let events = fixture.announcements.events
        #expect(events.filter(\.isAppended).count == 3)
        #expect(events.filter(\.isAlreadyInPlaylist).count == 1)
        let sharedIndex = try #require(ids.firstIndex(of: shared))
        let followerIndex = try #require(ids.firstIndex(of: leadingFollower))
        #expect(sharedIndex < followerIndex)
    }
}

/// Case predicates so an assertion can count one kind of announcement without spelling
/// out a `switch` at every call site.
private extension ChatDownloadAppendEvent {
    var isAppended: Bool {
        if case .appended = self { return true }
        return false
    }

    var isAlreadyInPlaylist: Bool {
        if case .alreadyInPlaylist = self { return true }
        return false
    }
}
