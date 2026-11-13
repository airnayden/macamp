import Foundation
import Persistence
import PlayerCoreTestSupport
import Testing
@testable import ViewModels

/// Records what each seam was handed, plus what the repository looked like AT THE
/// MOMENT the created-seam fired.
///
/// The membership snapshot is the whole point: it is what proves the seam runs
/// after `reorder` rather than beside it, which a call-count assertion cannot.
@MainActor
final class AssistantSeamRecorder {
    var created: [(proposalId: UUID, playlistId: Int64)] = []
    var membershipAtCallback: [Int64: [Int64]] = [:]
    var discarded: [UUID] = []

    /// Wires both seams on `harness`, snapshotting membership inside the created one.
    func attach(to harness: AssistantHarness) {
        let playlists = harness.playlists
        harness.viewModel.onPlaylistCreatedFromProposal = { [weak self] proposalId, playlistId in
            guard let self else { return }
            created.append((proposalId: proposalId, playlistId: playlistId))
            membershipAtCallback[playlistId] = playlists.recording.membership[playlistId] ?? []
        }
        harness.viewModel.onProposalDiscarded = { [weak self] proposalId in
            self?.discarded.append(proposalId)
        }
    }
}

/// Todo 6 acceptance: `(proposalId, playlistId)` is emitted strictly AFTER a
/// successful create — create + `reorder` + store removal — and the discard path
/// emits the proposal id instead. Ordering is the contract; a consumer flushes
/// held work on the first seam and evicts it on the second.
@MainActor
struct AssistantViewModelSeamTests {
    // MARK: Success ordering

    /// (a) One call, carrying the created id, made only once the playlist already
    /// holds the FULL proposal membership in proposal order — so a flush driven by
    /// this seam can never be wiped by the `reorder` that follows it.
    @Test func applyingACreateEmitsTheCreatedIdOnlyAfterMembershipIsWritten() async throws {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        let proposal = AssistantProposalFixture.createProposal(trackIds: [42, 7, 19])
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal)

        #expect(recorder.created.count == 1)
        let call = try #require(recorder.created.first)
        #expect(call.proposalId == proposal.id)
        let reorder = try #require(harness.playlists.recording.reorderCalls.first)
        #expect(call.playlistId == reorder.playlistId)
        #expect(recorder.membershipAtCallback[call.playlistId] == [42, 7, 19])
        #expect(recorder.discarded.isEmpty)
    }

    /// The removal is part of "succeeded": a consumer that reads the store from the
    /// callback must not find the proposal it is being told about still pending.
    @Test func theCreatedSeamFiresAfterTheProposalLeavesTheStore() async throws {
        let harness = AssistantHarness()
        let store = harness.store
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2])
        var stillPendingAtCallback: Bool?
        harness.viewModel.onPlaylistCreatedFromProposal = { proposalId, _ in
            stillPendingAtCallback = store.contains(id: proposalId)
        }
        store.add(proposal)

        try await harness.viewModel.apply(proposal)

        #expect(stillPendingAtCallback == false)
    }

    // MARK: Failure lock

    /// (b) The failure lock. `reorder` throws, `applyCreate` deletes the playlist it
    /// just made and rethrows — so nothing was created as far as the listener is
    /// concerned, the proposal stays, and the seam must stay silent.
    @Test func aFailedMembershipWriteNeverEmitsAndKeepsTheProposal() async {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
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
        #expect(recorder.created.isEmpty)
        #expect(recorder.discarded.isEmpty)
        #expect(harness.store.contains(id: proposal.id))
        #expect(harness.playlists.recording.playlists.isEmpty)
        #expect(harness.playlists.recording.deleteCalls.count == 1)
    }

    /// (c) A retry after that failure mints a DIFFERENT playlist id, and the seam
    /// carries the new one — the id the failed attempt created is gone, so a
    /// consumer keying on it must be told to move.
    @Test func retryingAfterAFailureEmitsTheNewPlaylistId() async throws {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        harness.playlists.setFailing([.reorder])
        let proposal = AssistantProposalFixture.createProposal(trackIds: [5, 6])
        harness.store.add(proposal)
        _ = try? await harness.viewModel.apply(proposal)
        let abandonedId = try #require(harness.playlists.recording.deleteCalls.first)

        harness.playlists.setFailing([])
        try await harness.viewModel.apply(proposal)

        #expect(recorder.created.count == 1)
        let call = try #require(recorder.created.first)
        #expect(call.proposalId == proposal.id)
        #expect(call.playlistId != abandonedId)
        #expect(recorder.membershipAtCallback[call.playlistId] == [5, 6])
        #expect(harness.store.isEmpty)
    }

    // MARK: Discard

    /// (d) Discard emits the proposal id on the OTHER seam, exactly once, and never
    /// the created one — nothing was created, so nothing may be flushed.
    @Test func discardEmitsTheProposalIdAndNeverTheCreatedSeam() {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1, 2, 3])
        harness.store.add(proposal)

        harness.viewModel.discard(proposal)

        #expect(recorder.discarded == [proposal.id])
        #expect(recorder.created.isEmpty)
        #expect(harness.store.isEmpty)
        #expect(harness.repositoryMutations == 0)
    }

    /// A second discard of the same handle removes nothing, so it announces nothing
    /// — the seam reports removals, not requests.
    @Test func discardingTwiceEmitsOnce() {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1])
        harness.store.add(proposal)

        harness.viewModel.discard(proposal)
        harness.viewModel.discard(proposal)

        #expect(recorder.discarded == [proposal.id])
    }

    /// Applying is not discarding: the successful path removes the proposal too, but
    /// a consumer told to EVICT there would throw away the work the create seam just
    /// asked it to flush.
    @Test func applyingNeverEmitsTheDiscardSeam() async throws {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        let proposal = AssistantProposalFixture.createProposal(trackIds: [9])
        harness.store.add(proposal)

        try await harness.viewModel.apply(proposal)

        #expect(recorder.discarded.isEmpty)
        #expect(recorder.created.count == 1)
    }

    // MARK: Other kinds, and handles the store never had

    /// (e) Only `.createPlaylist` creates a playlist, so only it may emit. An
    /// `.organize` rewrites an existing one and a `.rename` touches no membership.
    @Test func applyingANonCreateProposalNeverEmitsTheCreatedSeam() async throws {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        harness.playlists.configure { recording in
            recording.playlists[5] = PlaylistRecord(id: 5, name: "Old", profileId: 1)
            recording.playlists[11] = PlaylistRecord(id: 11, name: "Existing", profileId: 1)
            recording.membership[11] = [1, 2]
        }
        let diff = PlaylistOrganizeDiff(currentTrackIds: [1, 2], proposedTrackIds: [2, 1])
        let organize = AIProposal(profileId: 1, kind: .organize(playlistId: 11, diff: diff))
        let rename = AIProposal(profileId: 1, kind: .rename(playlistId: 5, name: "New"))
        harness.store.add(organize)
        harness.store.add(rename)

        try await harness.viewModel.apply(organize)
        try await harness.viewModel.apply(rename)

        #expect(recorder.created.isEmpty)
        #expect(recorder.discarded.isEmpty)
        #expect(harness.store.isEmpty)
    }

    /// A stale handle is rejected before the switch runs, so neither seam speaks for
    /// a proposal the store never had.
    @Test func applyingAProposalTheStoreNeverHadEmitsNothing() async {
        let harness = AssistantHarness()
        let recorder = AssistantSeamRecorder()
        recorder.attach(to: harness)
        let proposal = AssistantProposalFixture.createProposal(trackIds: [1])

        var caught: (any Error)?
        do {
            try await harness.viewModel.apply(proposal)
        } catch {
            caught = error
        }

        #expect(caught as? AssistantProposalError == .unknownProposal(id: proposal.id))
        #expect(recorder.created.isEmpty)
        #expect(recorder.discarded.isEmpty)
        #expect(harness.repositoryMutations == 0)
    }

    /// Both seams default to `nil`, which is what makes this change inert for every
    /// existing caller — an apply with nothing attached must still complete.
    @Test func unattachedSeamsLeaveApplyAndDiscardUnchanged() async throws {
        let harness = AssistantHarness()
        let applied = AssistantProposalFixture.createProposal(trackIds: [3, 4])
        let dropped = AssistantProposalFixture.createProposal(trackIds: [8])
        harness.store.add(applied)
        harness.store.add(dropped)

        #expect(harness.viewModel.onPlaylistCreatedFromProposal == nil)
        #expect(harness.viewModel.onProposalDiscarded == nil)
        try await harness.viewModel.apply(applied)
        harness.viewModel.discard(dropped)

        #expect(harness.store.isEmpty)
        #expect(harness.playlists.recording.reorderCalls.first?.orderedTrackIds == [3, 4])
    }
}
