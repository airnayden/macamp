// ProposalApplyPlaylistRefreshTests — a proposal apply refreshes the playlist that
// is OPEN, and refreshes NOTHING when a different one is.
//
// `ProposalPreviewSheet.performApply` used to reload only the playlist LIST, so a
// "Reorder by Energy" applied from an open playlist's own toolbar left that
// playlist's rows in their pre-apply order until the listener navigated away and
// back. The sheet now also reloads the affected playlist's tracks — but only when it
// is the one on screen.
//
// THE GUARD IS THE POINT, NOT THE RELOAD. `AppEnvironment` holds ONE shared
// `PlaylistViewModel` whose single `tracks` array feeds whichever playlist detail is
// mounted, so an unconditional reload for playlist B while playlist A is open would
// repaint A with B's rows. The mismatch case below is a hard assertion, not a note.
//
// The decision is asserted through the pure helper the call site is one `if let`
// over, and its CONSEQUENCE through a real `PlaylistViewModel` over a real in-memory
// `PlaylistRepository` — so "the wrong playlist's rows never land" is observed on the
// array the detail view actually reads, not asserted about a spy.
//
// A real repository rather than `PlayerCoreTestSupport`'s fake: `macampMacTests` does
// not expose that product, and the two existing local doubles in this target
// (`RecordingPlaybackController`, `HygieneDetailFixtures`) record that convention.
// Here an in-memory `AppDatabase` costs less than a hand-rolled conformer would.
import Foundation
import GRDB
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Proposal apply playlist refresh")
@MainActor
struct ProposalApplyPlaylistRefreshTests {
    @Test("an organize on the OPEN playlist names that playlist for a track reload")
    func organizeOnTheOpenPlaylistNamesIt() throws {
        let fixture = try ProposalRefreshFixture()

        let target = ProposalPreviewSheet.playlistNeedingTrackReload(
            after: Self.organizeProposal(playlistId: fixture.openPlaylistId),
            openDestination: .playlist(id: fixture.openPlaylistId)
        )

        #expect(target == fixture.openPlaylistId)
    }

    @Test("an organize on a DIFFERENT playlist names none")
    func organizeOnAnotherPlaylistNamesNone() throws {
        let fixture = try ProposalRefreshFixture()

        let target = ProposalPreviewSheet.playlistNeedingTrackReload(
            after: Self.organizeProposal(playlistId: fixture.otherPlaylistId),
            openDestination: .playlist(id: fixture.openPlaylistId)
        )

        #expect(target == nil)
    }

    @Test("applying from the assistant pane names none")
    func applyingFromTheAssistantPaneNamesNone() throws {
        let fixture = try ProposalRefreshFixture()

        let target = ProposalPreviewSheet.playlistNeedingTrackReload(
            after: Self.organizeProposal(playlistId: fixture.openPlaylistId),
            openDestination: .fixed(.assistant)
        )

        #expect(target == nil)
    }

    @Test("only an organize rewrites an existing playlist's membership")
    func onlyOrganizeRewritesMembership() {
        let organize = AIProposal.Kind.organize(playlistId: 7, diff: Self.diff)

        #expect(ProposalPreviewSheet.rewrittenPlaylistId(in: organize) == 7)
        #expect(ProposalPreviewSheet.rewrittenPlaylistId(in: .rename(playlistId: 7, name: "Renamed")) == nil)
        #expect(ProposalPreviewSheet.rewrittenPlaylistId(in: .tagChangeSet(patches: [])) == nil)
        #expect(ProposalPreviewSheet.rewrittenPlaylistId(in: .createPlaylist(
            CreatePlaylistRequest(draft: .empty(), name: "New")
        )) == nil)
    }

    @Test("the named reload really repaints the open playlist's rows")
    func theNamedReloadRepaintsTheOpenPlaylist() async throws {
        let fixture = try ProposalRefreshFixture()
        let playlists = fixture.viewModel()
        try await playlists.loadInitialTracks(in: fixture.openPlaylistId)
        #expect(playlists.tracks.compactMap(\.track.id) == [1, 2])

        try fixture.reorder(playlistId: fixture.openPlaylistId, to: [2, 1])
        let target = try #require(ProposalPreviewSheet.playlistNeedingTrackReload(
            after: Self.organizeProposal(playlistId: fixture.openPlaylistId),
            openDestination: .playlist(id: fixture.openPlaylistId)
        ))
        try await playlists.loadInitialTracks(in: target)

        #expect(playlists.tracks.compactMap(\.track.id) == [2, 1])
    }

    @Test("a different playlist's apply never repaints the open playlist's rows")
    func anotherPlaylistsApplyLeavesTheOpenRowsAlone() async throws {
        let fixture = try ProposalRefreshFixture()
        let playlists = fixture.viewModel()
        try await playlists.loadInitialTracks(in: fixture.openPlaylistId)

        try fixture.reorder(playlistId: fixture.otherPlaylistId, to: [4, 3])
        let target = ProposalPreviewSheet.playlistNeedingTrackReload(
            after: Self.organizeProposal(playlistId: fixture.otherPlaylistId),
            openDestination: .playlist(id: fixture.openPlaylistId)
        )
        #expect(target == nil)
        if let target {
            try await playlists.loadInitialTracks(in: target)
        }

        #expect(playlists.tracks.compactMap(\.track.id) == [1, 2])
    }

    // MARK: Proposal fixtures

    private static let diff = PlaylistOrganizeDiff(currentTrackIds: [1, 2], proposedTrackIds: [2, 1])

    private static func organizeProposal(playlistId: Int64) -> AIProposal {
        AIProposal(
            profileId: ProfileRecord.guestID,
            kind: .organize(playlistId: playlistId, diff: diff)
        )
    }
}

// MARK: - Library fixture

/// Two Guest playlists over four tracks: "Open" holds tracks 1–2, "Other" holds 3–4.
///
/// Distinct memberships are what makes the mismatch case observable — a reload of the
/// wrong playlist would put `[3, 4]` where `[1, 2]` belongs.
private struct ProposalRefreshFixture {
    let database: AppDatabase
    let repository: PlaylistRepository
    let openPlaylistId: Int64
    let otherPlaylistId: Int64

    init() throws {
        database = try AppDatabase(DatabaseQueue())
        try database.writer.write { db in
            for index in 1 ... 4 {
                var track = TrackRecord(
                    filePath: "/fixtures/track-\(index).mp3",
                    title: "Fixture \(index)",
                    sortTitle: "fixture \(index)",
                    artistName: "Fixture Artist",
                    duration: 100,
                    availability: .present
                )
                try track.insert(db)
            }
        }
        repository = PlaylistRepository(database)
        openPlaylistId = try Self.playlist(named: "Open", holding: [1, 2], in: repository)
        otherPlaylistId = try Self.playlist(named: "Other", holding: [3, 4], in: repository)
    }

    @MainActor
    func viewModel() -> PlaylistViewModel {
        PlaylistViewModel(repository: repository, activeProfileId: ProfileRecord.guestID)
    }

    /// Stands in for what an applied `.organize` writes: one transactional rewrite.
    func reorder(playlistId: Int64, to orderedTrackIds: [Int64]) throws {
        try repository.reorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
    }

    private static func playlist(
        named name: String,
        holding trackIds: [Int64],
        in repository: PlaylistRepository
    ) throws -> Int64 {
        let created = try repository.create(named: name, profileId: ProfileRecord.guestID)
        let playlistId = try #require(created.id)
        try repository.reorder(playlistId: playlistId, orderedTrackIds: trackIds)
        return playlistId
    }
}
