import Foundation
import Metadata
import Persistence
import PlayerCoreTestSupport
import Testing
@testable import ViewModels

/// Todo 17 acceptance: `apply` is the ONLY write path, it routes each proposal kind
/// to exactly one seam, a tag change-set is inert without `confirmedBatch`, a
/// failure leaves the proposal in the store, and `discard` touches nothing.
@MainActor
struct AssistantViewModelApplyTests {
    // MARK: Create

    @Test func applyingACreateWritesTheDraftsExactOrderInOneTransactionalCall() async throws {
        let harness = AssistantHarness()
        let proposal = AssistantProposalFixture.createProposal(
            trackIds: [42, 7, 19],
            name: "Upbeat 90s Rock",
            profileId: 2
        )
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal)

        let recording = harness.playlists.recording
        #expect(recording.createdNames == ["Upbeat 90s Rock"])
        #expect(recording.reorderCalls.count == 1)
        #expect(recording.reorderCalls.first?.orderedTrackIds == [42, 7, 19])
        #expect(recording.playlists.values.first?.profileId == 2)
        #expect(recording.membership[recording.reorderCalls[0].playlistId] == [42, 7, 19])
        #expect(harness.store.isEmpty)
    }

    /// Membership is ONE `reorder`, never N `addTrack`s: `reorder` rewrites the
    /// whole list in a single transaction, so there is no window in which the
    /// playlist exists half-filled.
    @Test func createNeverAppendsTrackByTrack() async throws {
        let harness = AssistantHarness()
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2, 3, 4, 5])
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal)

        #expect(harness.playlists.recording.addTrackCalls.isEmpty)
        #expect(harness.playlists.recording.reorderCalls.count == 1)
    }

    @Test func aFailedMembershipWriteRollsBackTheCreatedPlaylistAndKeepsTheProposal() async throws {
        let harness = AssistantHarness()
        harness.playlists.setFailing([.reorder])
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2])
        harness.store.add(proposal)

        var caught: (any Error)?
        do {
            try await harness.viewModel.apply(proposal)
        } catch {
            caught = error
        }

        #expect(caught as? FakePlaylistRepositoryError == .forcedFailure)
        let recording = harness.playlists.recording
        #expect(recording.createdNames.count == 1)
        #expect(recording.deleteCalls.count == 1)
        #expect(recording.playlists.isEmpty)
        #expect(harness.store.contains(id: proposal.id))
    }

    // MARK: Organize + rename

    @Test func applyingAnOrganizeRewritesMembershipFromTheDiffsProposedOrder() async throws {
        let harness = AssistantHarness()
        harness.playlists.configure { recording in
            recording.playlists[11] = PlaylistRecord(id: 11, name: "Existing", profileId: 1)
            recording.membership[11] = [1, 2, 3]
        }
        let diff = PlaylistOrganizeDiff(currentTrackIds: [1, 2, 3], proposedTrackIds: [3, 1, 9])
        let proposal = AIProposal(profileId: 1, kind: .organize(playlistId: 11, diff: diff))
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal)

        #expect(harness.playlists.recording.reorderCalls == [
            .init(playlistId: 11, orderedTrackIds: [3, 1, 9]),
        ])
        #expect(harness.playlists.recording.createdNames.isEmpty)
        #expect(harness.store.isEmpty)
    }

    @Test func applyingARenameUpdatesTheStoredPlaylist() async throws {
        let harness = AssistantHarness()
        harness.playlists.configure { recording in
            recording.playlists[5] = PlaylistRecord(id: 5, name: "Old", profileId: 1)
        }
        let proposal = AIProposal(profileId: 1, kind: .rename(playlistId: 5, name: "New"))
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal)

        #expect(harness.playlists.recording.updateCalls.map(\.name) == ["New"])
        #expect(harness.playlists.recording.playlists[5]?.name == "New")
        #expect(harness.store.isEmpty)
    }

    @Test func renamingAMissingPlaylistThrowsAndWritesNothing() async {
        let harness = AssistantHarness()
        let proposal = AIProposal(profileId: 1, kind: .rename(playlistId: 404, name: "New"))
        harness.store.add(proposal)

        var caught: (any Error)?
        do {
            try await harness.viewModel.apply(proposal)
        } catch {
            caught = error
        }

        #expect(caught as? AssistantProposalError == .playlistNotFound(id: 404))
        #expect(harness.repositoryMutations == 0)
        #expect(harness.store.contains(id: proposal.id))
    }

    // MARK: Tag change-sets

    @Test func aTagChangeSetWithoutConfirmationThrowsAndWritesNothing() async {
        let harness = AssistantHarness()
        let proposal = AssistantProposalFixture.tagProposal([
            AssistantProposalFixture.patch(trackId: 1, genre: "Hip-Hop"),
            AssistantProposalFixture.patch(trackId: 2, genre: "Hip-Hop"),
        ])
        harness.store.add(proposal)

        var caught: (any Error)?
        do {
            try await harness.viewModel.apply(proposal)
        } catch {
            caught = error
        }

        #expect(caught as? AssistantProposalError == .batchNotConfirmed)
        #expect(harness.tagWrites == 0)
        #expect(harness.repositoryMutations == 0)
        #expect(harness.store.contains(id: proposal.id))
    }

    @Test func aConfirmedTagChangeSetWritesEveryPatchAndRegistersEachSelfWrite() async throws {
        let harness = AssistantHarness()
        let patches = [
            AssistantProposalFixture.patch(trackId: 1, genre: "Hip-Hop"),
            AssistantProposalFixture.patch(trackId: 2, genre: "Hip-Hop"),
        ]
        let proposal = AssistantProposalFixture.tagProposal(patches)
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal, confirmedBatch: true)

        let calls = harness.writer.calls
        #expect(calls.map(\.url) == patches.map(\.fileURL))
        #expect(calls.map(\.metadata) == patches.map(\.patch))
        #expect(patches.allSatisfy { harness.registry.isSelfWrite($0.fileURL) })
        #expect(harness.store.isEmpty)
    }

    @Test func aTagChangeSetWithoutAWriterThrowsAndWritesNothing() async {
        let harness = AssistantHarness(includeWriter: false)
        let proposal = AssistantProposalFixture.tagProposal([
            AssistantProposalFixture.patch(trackId: 1, genre: "Rock"),
        ])
        harness.store.add(proposal)

        var caught: (any Error)?
        do {
            try await harness.viewModel.apply(proposal, confirmedBatch: true)
        } catch {
            caught = error
        }

        #expect(caught as? AssistantProposalError == .metadataWriterUnavailable)
        #expect(harness.tagWrites == 0)
        #expect(harness.store.contains(id: proposal.id))
    }

    // MARK: Discard + stale handles

    @Test func discardRemovesTheProposalAndTouchesNothingElse() {
        let harness = AssistantHarness()
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2, 3])
        harness.store.add(proposal)

        harness.viewModel.discard(proposal)

        #expect(harness.store.isEmpty)
        #expect(harness.repositoryMutations == 0)
        #expect(harness.tagWrites == 0)
        #expect(harness.playlists.recording.playlists.isEmpty)
        #expect(harness.smartPlaylists.recording.evaluateRequests.isEmpty)
    }

    @Test func applyingAProposalThatIsNoLongerInTheStoreThrowsAndWritesNothing() async {
        let harness = AssistantHarness()
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1])
        harness.store.add(proposal)
        harness.viewModel.discard(proposal)

        var caught: (any Error)?
        do {
            try await harness.viewModel.apply(proposal)
        } catch {
            caught = error
        }

        #expect(caught as? AssistantProposalError == .unknownProposal(id: proposal.id))
        #expect(harness.repositoryMutations == 0)
    }

    /// The whole propose-and-preview contract in one assertion: nothing at all
    /// reaches a repository until `apply` is called.
    @Test func fillingTheStoreWritesNothing() {
        let harness = AssistantHarness()

        harness.store.add(AssistantProposalFixture.createProposal(trackIds: [1, 2]))
        harness.store.add(AssistantProposalFixture.tagProposal([
            AssistantProposalFixture.patch(trackId: 3, genre: "Jazz"),
        ]))

        #expect(harness.store.proposals.count == 2)
        #expect(harness.repositoryMutations == 0)
        #expect(harness.tagWrites == 0)
        #expect(harness.smartPlaylists.recording.evaluateRequests.isEmpty)
    }
}
