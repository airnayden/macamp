import Foundation
import Metadata
import Services
import Testing
@testable import ViewModels

/// The `HygieneFinding -> AIProposal` mapping.
///
/// The findings below MIRROR the twenty-track planted library `InsightTests`'
/// `LibraryHygieneFixture` builds — same ids, same playlist, same spellings — so the
/// two suites together prove the whole path: three planted issues produce three
/// findings there, and those three findings produce three proposals here.
///
/// No database and no repository: the mapping is a pure function, which is exactly
/// what makes "proposing writes nothing" checkable rather than merely intended.
@MainActor
@Suite("Assistant hygiene mapping")
struct AssistantViewModelHygieneTests {
    @Test("The three planted findings map to three proposals")
    func plantedFindingsMapToThreeProposals() {
        let proposals = AssistantViewModel.hygieneProposals(
            for: HygieneFindingFixture.planted(),
            profileId: HygieneFindingFixture.profileId
        )

        #expect(proposals.count == 3)
        #expect(proposals.map(\.kindName) == ["organize", "tagChangeSet", "tagChangeSet"])
    }

    @Test("A duplicate maps to the membership rewrite, and to nothing else")
    func duplicateMapsToMembershipRewrite() throws {
        let proposals = AssistantViewModel.hygieneProposals(
            for: [.duplicate(HygieneFindingFixture.duplicateGroup())],
            profileId: HygieneFindingFixture.profileId
        )

        #expect(proposals.count == 1)
        let proposal = try #require(proposals.first)
        guard case let .organize(playlistId, diff) = proposal.kind else {
            Issue.record("expected an organize proposal")
            return
        }
        #expect(playlistId == 1)
        #expect(diff.proposedTrackIds == [1, 3])
        #expect(diff.removals == [4])
        #expect(diff.additions.isEmpty)
        // Nothing in the proposal names a file: only a membership was rewritten.
        #expect(!proposal.requiresBatchConfirmation)
    }

    @Test("A duplicate no playlist lists twice maps to no proposal at all")
    func duplicateWithNoCleanupMapsToNothing() {
        let group = DuplicateGroup(
            canonical: HygieneFindingFixture.track(3),
            duplicates: [HygieneFindingFixture.track(4)],
            playlistCleanups: []
        )

        let proposals = AssistantViewModel.hygieneProposals(
            for: [.duplicate(group)],
            profileId: HygieneFindingFixture.profileId
        )

        #expect(proposals.isEmpty)
    }

    @Test("A genre cluster patches only the minority-spelled tracks")
    func genreClusterPatchesOnlyMinoritySpellings() throws {
        let proposals = AssistantViewModel.hygieneProposals(
            for: [.genreCluster(HygieneFindingFixture.genreCluster())],
            profileId: HygieneFindingFixture.profileId
        )

        let proposal = try #require(proposals.first)
        guard case let .tagChangeSet(patches) = proposal.kind else {
            Issue.record("expected a tagChangeSet proposal")
            return
        }
        #expect(patches.map(\.trackId) == [8])
        #expect(patches.first?.patch.genre == "Hip-Hop")
        #expect(patches.first?.fileURL == URL(fileURLWithPath: "/Music/8.flac"))
        // Every tag proposal needs the second confirmation, hygiene included.
        #expect(proposal.requiresBatchConfirmation)
    }

    @Test("Metadata gaps merge into one batch, and undeducible ones contribute nothing")
    func metadataGapsMergeIntoOneBatch() throws {
        let findings: [HygieneFinding] = [
            .metadataGap(HygieneFindingFixture.gap(10, artist: "Gap Artist")),
            .metadataGap(HygieneFindingFixture.gap(11, artist: "Other Artist")),
            .metadataGap(HygieneFindingFixture.gap(12, artist: nil)),
        ]

        let proposals = AssistantViewModel.hygieneProposals(
            for: findings,
            profileId: HygieneFindingFixture.profileId
        )

        #expect(proposals.count == 1)
        let proposal = try #require(proposals.first)
        guard case let .tagChangeSet(patches) = proposal.kind else {
            Issue.record("expected a tagChangeSet proposal")
            return
        }
        // Track 12 has no artist to copy, so no value is invented for it.
        #expect(patches.map(\.trackId) == [10, 11])
        #expect(patches.map(\.patch.albumArtist) == ["Gap Artist", "Other Artist"])
        #expect(patches.allSatisfy { $0.patch.genre == nil && $0.patch.year == nil })
    }

    @Test("Filing hygiene proposals fills the store and writes nothing")
    func filingProposalsWritesNothing() {
        let harness = AssistantHarness()

        let filed = harness.viewModel.fileHygieneProposals(
            for: HygieneFindingFixture.planted(),
            profileId: HygieneFindingFixture.profileId
        )

        #expect(filed.count == 3)
        #expect(harness.store.proposals.map(\.id) == filed.map(\.id))
        #expect(harness.repositoryMutations == 0)
        #expect(harness.tagWrites == 0)
    }

    @Test("A clean library files no proposals")
    func cleanLibraryFilesNothing() {
        let harness = AssistantHarness()

        let filed = harness.viewModel.fileHygieneProposals(for: [], profileId: 1)

        #expect(filed.isEmpty)
        #expect(harness.store.isEmpty)
        #expect(harness.repositoryMutations == 0)
        #expect(harness.tagWrites == 0)
    }
}

// MARK: - Findings mirroring the InsightTests fixture

/// Builders for the findings the twenty-track planted library produces.
enum HygieneFindingFixture {
    static let profileId: Int64 = 1

    static func planted() -> [HygieneFinding] {
        [
            .duplicate(duplicateGroup()),
            .genreCluster(genreCluster()),
            .metadataGap(gap(10, artist: "Gap Artist")),
        ]
    }

    static func track(_ trackId: Int64, artist: String? = "Radiohead") -> HygieneTrack {
        HygieneTrack(
            trackId: trackId,
            filePath: "/Music/\(trackId).flac",
            title: "Paranoid Android",
            artistName: artist
        )
    }

    /// Ids 3 and 4, listed in playlist 1 as `[1, 3, 4]`.
    static func duplicateGroup() -> DuplicateGroup {
        DuplicateGroup(
            canonical: track(3),
            duplicates: [track(4)],
            playlistCleanups: [
                DuplicatePlaylistCleanup(
                    playlistId: 1,
                    currentTrackIds: [1, 3, 4],
                    proposedTrackIds: [1, 3]
                ),
            ]
        )
    }

    /// "Hip-Hop" twice, "hip hop" once — only the latter is retagged.
    static func genreCluster() -> GenreCluster {
        GenreCluster(
            canonicalGenre: "Hip-Hop",
            canonicalTrackCount: 2,
            variants: [
                GenreVariant(
                    genre: "hip hop",
                    tracks: [
                        HygieneTrack(
                            trackId: 8,
                            filePath: "/Music/8.flac",
                            title: "Verse Three",
                            artistName: "Filler Artist"
                        ),
                    ]
                ),
            ]
        )
    }

    static func gap(_ trackId: Int64, artist: String?) -> MetadataGap {
        MetadataGap(
            track: HygieneTrack(
                trackId: trackId,
                filePath: "/Music/\(trackId).flac",
                title: "Untagged Demo",
                artistName: artist
            ),
            missingFields: [.genre, .year, .albumArtist],
            suggestedAlbumArtist: artist
        )
    }
}

private extension AIProposal {
    /// The kind's name, so an ordering assertion reads as a list rather than as
    /// four nested pattern matches.
    var kindName: String {
        switch kind {
        case .createPlaylist: "createPlaylist"
        case .organize: "organize"
        case .rename: "rename"
        case .tagChangeSet: "tagChangeSet"
        }
    }
}
