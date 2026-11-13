// AIProposalExclusionTests — what a proposal becomes when the listener unticks rows.
//
// Four kinds, four meanings, and one identity law: with nothing excluded the
// narrowing must be a no-op, because that is the state every preview sheet opens in.
// If `excluding([])` ever stopped returning an equal proposal, every ordinary apply
// would start writing a subtly different list than the one previewed.
//
// The organize case gets the most coverage because it is the only one where
// "leave this track alone" is more than a filter — dropping a track from
// ``PlaylistOrganizeDiff/proposedTrackIds`` DELETES it from the playlist, so an
// unticked REMOVAL has to be put back rather than left out.
import Foundation
import Metadata
import Testing
@testable import ViewModels

@Suite("AIProposal exclusion")
struct AIProposalExclusionTests {
    // MARK: Identity

    @Test("excluding nothing returns an equal proposal for every kind")
    func excludingNothingIsIdentity() {
        let create = AssistantProposalFixture.createProposal(trackIds: [1, 2, 3])
        let organize = Self.organizeProposal(current: [1, 2, 3], proposed: [3, 1])
        let rename = AIProposal(profileId: 1, kind: .rename(playlistId: 7, name: "Renamed"))
        let tags = AssistantProposalFixture.tagProposal([
            AssistantProposalFixture.patch(trackId: 1, genre: "Shoegaze"),
            AssistantProposalFixture.patch(trackId: 2, genre: "Shoegaze"),
        ])

        for proposal in [create, organize, rename, tags] {
            #expect(proposal.excluding(trackIds: []) == proposal)
        }
    }

    @Test("the filtered copy keeps the original id, so apply still recognises it")
    func theFilteredCopyKeepsItsIdentity() {
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2, 3])
        let narrowed = proposal.excluding(trackIds: [2])

        #expect(narrowed.id == proposal.id)
        #expect(narrowed.profileId == proposal.profileId)
    }

    // MARK: Create

    @Test("an excluded track is dropped from a create proposal's draft and its count")
    func createDropsExcludedEntries() throws {
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2, 3, 4])
        let narrowed = proposal.excluding(trackIds: [2, 4])

        let request = try #require(Self.createRequest(narrowed))
        #expect(request.orderedTrackIds == [1, 3])
        #expect(request.draft.nameHint.trackCount == 2)
        #expect(narrowed.affectedCount == 2)
        #expect(request.name == "Fixture Mix")
    }

    @Test("excluding every track empties a create proposal rather than failing")
    func createCanBeEmptiedCompletely() throws {
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2])
        let narrowed = proposal.excluding(trackIds: [1, 2])

        let request = try #require(Self.createRequest(narrowed))
        #expect(request.orderedTrackIds.isEmpty)
        #expect(narrowed.affectedCount == 0)
    }

    // MARK: Organize

    @Test("an unticked ADDITION is simply not added")
    func organizeDropsAnExcludedAddition() throws {
        let proposal = Self.organizeProposal(current: [1, 2], proposed: [1, 2, 9])
        let diff = try #require(Self.diff(proposal.excluding(trackIds: [9])))

        #expect(diff.proposedTrackIds == [1, 2])
        #expect(diff.additions.isEmpty)
        #expect(diff.isEmpty)
    }

    /// The case a naive filter gets exactly backwards: the id is absent from
    /// `proposedTrackIds` precisely BECAUSE the proposal wanted it gone, so
    /// "exclude it" has to put it back.
    @Test("an unticked REMOVAL is restored at its current position")
    func organizeRestoresAnExcludedRemoval() throws {
        let proposal = Self.organizeProposal(current: [1, 2, 3], proposed: [1, 3])
        let diff = try #require(Self.diff(proposal.excluding(trackIds: [2])))

        #expect(diff.proposedTrackIds == [1, 2, 3])
        #expect(diff.removals.isEmpty)
        #expect(diff.isEmpty)
    }

    @Test("an unticked MOVE is pinned back to its current index")
    func organizePinsAnExcludedMove() throws {
        let proposal = Self.organizeProposal(current: [1, 2, 3], proposed: [3, 2, 1])
        let diff = try #require(Self.diff(proposal.excluding(trackIds: [1])))

        #expect(diff.proposedTrackIds == [1, 3, 2])
        #expect(!diff.moves.contains(1))
    }

    @Test("several exclusions land in their original relative order")
    func organizePinsSeveralExclusionsInOrder() throws {
        let proposal = Self.organizeProposal(current: [1, 2, 3, 4], proposed: [4, 3, 2, 1])
        let diff = try #require(Self.diff(proposal.excluding(trackIds: [1, 3])))

        #expect(diff.proposedTrackIds == [1, 4, 3, 2])
    }

    @Test("unticking every change turns an organize proposal into a no-op")
    func organizeCanBeReducedToNothing() throws {
        let proposal = Self.organizeProposal(current: [1, 2, 3], proposed: [3, 1])
        let diff = try #require(Self.diff(proposal.excluding(trackIds: [1, 2, 3])))

        #expect(diff.proposedTrackIds == [1, 2, 3])
        #expect(diff.isEmpty)
    }

    // MARK: Tags

    @Test("an excluded track's file is not in the patch list any more")
    func tagsDropExcludedPatches() throws {
        let proposal = AssistantProposalFixture.tagProposal([
            AssistantProposalFixture.patch(trackId: 1, genre: "Shoegaze"),
            AssistantProposalFixture.patch(trackId: 2, genre: "Shoegaze"),
            AssistantProposalFixture.patch(trackId: 3, genre: "Shoegaze"),
        ])
        let narrowed = proposal.excluding(trackIds: [2])

        let patches = try #require(Self.patches(narrowed))
        #expect(patches.map(\.trackId) == [1, 3])
        #expect(narrowed.affectedCount == 2)
        #expect(narrowed.requiresBatchConfirmation)
    }

    // MARK: Rename

    @Test("a rename carries no track ids, so exclusion cannot change it")
    func renameIsUntouched() {
        let proposal = AIProposal(profileId: 1, kind: .rename(playlistId: 7, name: "Renamed"))

        #expect(proposal.excluding(trackIds: [1, 2, 3]) == proposal)
    }
}

// MARK: - Fixtures

private extension AIProposalExclusionTests {
    static func organizeProposal(current: [Int64], proposed: [Int64]) -> AIProposal {
        AIProposal(
            profileId: 1,
            kind: .organize(
                playlistId: 7,
                diff: PlaylistOrganizeDiff(currentTrackIds: current, proposedTrackIds: proposed)
            )
        )
    }

    static func createRequest(_ proposal: AIProposal) -> CreatePlaylistRequest? {
        guard case let .createPlaylist(request) = proposal.kind else { return nil }
        return request
    }

    static func diff(_ proposal: AIProposal) -> PlaylistOrganizeDiff? {
        guard case let .organize(_, diff) = proposal.kind else { return nil }
        return diff
    }

    static func patches(_ proposal: AIProposal) -> [TagPatch]? {
        guard case let .tagChangeSet(patches) = proposal.kind else { return nil }
        return patches
    }
}
