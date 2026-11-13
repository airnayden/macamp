import Foundation
import Testing
@testable import ViewModels

/// Todo 17 acceptance: the proposal store is an inert, in-memory holding pen —
/// stable ids, order-preserving, equality-guarded, and reachable by nothing that
/// could persist it.
@MainActor
struct ProposalStoreTests {
    @Test func addsInOrderAndReportsTheLatest() {
        let store = ProposalStore()
        let first = AssistantProposalFixture.createProposal(trackIds: [1, 2], name: "First")
        let second = AssistantProposalFixture.createProposal(trackIds: [3], name: "Second")

        store.add(first)
        store.add(second)

        #expect(store.proposals.map(\.id) == [first.id, second.id])
        #expect(store.latest?.id == second.id)
        #expect(!store.isEmpty)
    }

    @Test func reAddingTheSameIdReplacesInPlaceRatherThanAppending() {
        let store = ProposalStore()
        let original = AssistantProposalFixture.createProposal(trackIds: [1], name: "Original")
        let other = AssistantProposalFixture.createProposal(trackIds: [9], name: "Other")
        let revised = AIProposal(
            id: original.id,
            profileId: original.profileId,
            kind: .rename(playlistId: 7, name: "Revised")
        )

        store.add(original)
        store.add(other)
        store.add(revised)

        #expect(store.proposals.count == 2)
        #expect(store.proposals.map(\.id) == [original.id, other.id])
        #expect(store.proposal(id: original.id) == revised)
    }

    @Test func removeTargetsTheIdAndLeavesEverythingElseUntouched() {
        let store = ProposalStore()
        let keep = AssistantProposalFixture.createProposal(trackIds: [1])
        let drop = AssistantProposalFixture.createProposal(trackIds: [2])
        store.add(keep)
        store.add(drop)

        store.remove(drop)

        #expect(store.proposals.map(\.id) == [keep.id])
        #expect(!store.contains(id: drop.id))
        #expect(store.contains(id: keep.id))
    }

    @Test func removingAnUnknownIdIsANoOp() {
        let store = ProposalStore()
        let kept = AssistantProposalFixture.createProposal(trackIds: [1])
        store.add(kept)

        store.remove(id: UUID())

        #expect(store.proposals.map(\.id) == [kept.id])
    }

    @Test func clearEmptiesTheStore() {
        let store = ProposalStore()
        store.add(AssistantProposalFixture.createProposal(trackIds: [1]))
        store.add(AssistantProposalFixture.createProposal(trackIds: [2]))

        store.clear()

        #expect(store.isEmpty)
        #expect(store.latest == nil)
    }

    /// Two proposals built from IDENTICAL inputs are still distinct objects — the
    /// id is minted per construction, never derived from the payload, so
    /// discarding one can never remove the other.
    @Test func identicalPayloadsGetDistinctIds() {
        let one = AssistantProposalFixture.createProposal(trackIds: [1, 2], name: "Same")
        let two = AssistantProposalFixture.createProposal(trackIds: [1, 2], name: "Same")

        #expect(one.id != two.id)

        let store = ProposalStore()
        store.add(one)
        store.add(two)
        store.remove(one)

        #expect(store.proposals.map(\.id) == [two.id])
    }

    @Test func requiresBatchConfirmationOnlyForTagChangeSets() {
        let create = AssistantProposalFixture.createProposal(trackIds: [1])
        let rename = AIProposal(profileId: 1, kind: .rename(playlistId: 3, name: "New"))
        let tags = AssistantProposalFixture.tagProposal([
            AssistantProposalFixture.patch(trackId: 1, genre: "Rock"),
        ])

        #expect(!create.requiresBatchConfirmation)
        #expect(!rename.requiresBatchConfirmation)
        #expect(tags.requiresBatchConfirmation)
        #expect(create.affectedCount == 1)
        #expect(tags.affectedCount == 1)
    }
}

/// The organize diff is derived from the two memberships, so a preview can never
/// describe a change other than the one apply will make.
struct PlaylistOrganizeDiffTests {
    @Test func derivesAdditionsRemovalsAndMoves() {
        let diff = PlaylistOrganizeDiff(
            currentTrackIds: [1, 2, 3, 4],
            proposedTrackIds: [3, 1, 5]
        )

        #expect(diff.proposedTrackIds == [3, 1, 5])
        #expect(diff.additions == [5])
        #expect(diff.removals == [2, 4])
        #expect(diff.moves == [3, 1])
        #expect(!diff.isEmpty)
    }

    @Test func anUnchangedMembershipIsEmpty() {
        let diff = PlaylistOrganizeDiff(currentTrackIds: [1, 2], proposedTrackIds: [1, 2])

        #expect(diff.isEmpty)
        #expect(diff.proposedTrackIds == [1, 2])
    }

    @Test func duplicateIdsCollapseToTheirFirstOccurrence() {
        let diff = PlaylistOrganizeDiff(currentTrackIds: [1, 1, 2], proposedTrackIds: [2, 2, 1])

        #expect(diff.proposedTrackIds == [2, 1])
        #expect(diff.additions.isEmpty)
        #expect(diff.removals.isEmpty)
    }
}
