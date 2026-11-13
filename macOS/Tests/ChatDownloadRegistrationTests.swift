// ChatDownloadRegistrationTests — what "Download selected" registers, and what it
// refuses to register.
//
// The request half of the wiring, split from `ChatDownloadWiringTests` for the 400-line
// budget. Same harness, same discipline: the production `handleChatDownloadRequest` is
// what runs, over a scripted queue so the outcome the depth cap produces can be stated
// exactly rather than approximated by a thousand real rows.
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Chat download registration", .serialized)
@MainActor
struct ChatDownloadRegistrationTests {
    @Test("a playlist target registers every id, for the profile the request named")
    func aPlaylistTargetRegistersEveryID() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second],
            appendTarget: .playlist(12),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 2)
        #expect(harness.queueDouble.enqueuedURLs.first?.count == 2)
        #expect(harness.registry.claimRegistrations(videoID: ChatDownloadFixtureIDs.first)
            == [SuggestionDownloadRegistration(target: .playlist(12), profileId: ProfileRecord.guestID)])
    }

    /// A pending proposal's profile comes from the `ProposalStore`, not from the
    /// request: the request's own field is only meaningful for a real playlist id.
    @Test("a pending-proposal target reads its profile from the ProposalStore")
    func aPendingProposalReadsItsProfileFromTheStore() async throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: true)
        defer { harness.cleanUp() }
        let store = try #require(harness.environment.intelligence?.proposals)
        let proposal = Self.proposal(profileId: 77)
        store.add(proposal)

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first],
            appendTarget: .pendingProposal(proposal.id),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.claimRegistrations(videoID: ChatDownloadFixtureIDs.first)
            == [SuggestionDownloadRegistration(target: .pendingProposal(proposal.id), profileId: 77)])
    }

    /// APPLIED-and-removed: the resolution outlives the proposal, so the registration is
    /// swapped for the playlist that really exists.
    @Test("a proposal that was applied and removed registers against the playlist it became")
    func anAppliedProposalRegistersAgainstItsPlaylist() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let proposalId = UUID()
        harness.registry.resolveProposal(proposalId, playlistId: 31)

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first],
            appendTarget: .pendingProposal(proposalId),
            appendProfileId: nil
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.claimRegistrations(videoID: ChatDownloadFixtureIDs.first)
            == [SuggestionDownloadRegistration(target: .playlist(31), profileId: ProfileRecord.guestID)])
    }

    /// DISCARDED: no resolution and no proposal. A `.pendingProposal` registration left
    /// here would park appends no future apply could ever flush, so nothing is
    /// registered and the listener is told.
    @Test("a discarded proposal registers nothing and says so once")
    func aDiscardedProposalRegistersNothing() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second],
            appendTarget: .pendingProposal(UUID()),
            appendProfileId: nil
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 0)
        #expect(harness.queueDouble.enqueuedURLs.first?.count == 2)
        #expect(harness.activeToastText == String(localized: MacAMPStrings.chatDownloadNoPlaylistToast))
    }

    // MARK: - QA (failure)

    @Test("a request with no target registers nothing and enqueues normally")
    func aTargetlessRequestJustEnqueues() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second],
            appendTarget: nil,
            appendProfileId: nil
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 0)
        #expect(try harness.queueDouble.enqueuedURLs == [[
            downloadFixtureURL("https://www.youtube.com/watch?v=\(ChatDownloadFixtureIDs.first)"),
            downloadFixtureURL("https://www.youtube.com/watch?v=\(ChatDownloadFixtureIDs.second)"),
        ]])
        #expect(harness.activeToastText == nil)
    }

    /// The depth cap reports `added: 0, duplicatesDropped: 0` — a cap-refused row is not
    /// a duplicate — so the shortfall is the whole batch and every registration this
    /// batch made must go, or each one leaks with no terminal state left to evict it.
    @Test("a queue-full batch ends with ZERO registrations and exactly one queue-full notice")
    func aQueueFullBatchLeavesNothingRegistered() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        harness.queueDouble.outcome = EnqueueOutcome(added: 0, duplicatesDropped: 0)

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second],
            appendTarget: .playlist(5),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 0)
        #expect(harness.activeToastText == String(localized: MacAMPStrings.chatDownloadQueueFullToast))
    }

    /// Deduping against a row already in flight is NOT a shortfall — the in-flight
    /// download will serve the new target too (fan-out), so the registration stands.
    @Test("a fully deduped batch keeps its registrations")
    func aDedupedBatchKeepsItsRegistrations() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        harness.queueDouble.outcome = EnqueueOutcome(added: 0, duplicatesDropped: 2)

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second],
            appendTarget: .playlist(5),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 2)
        #expect(harness.activeToastText == nil)
    }

    /// An id the normalizer will not build a watch URL for can never be enqueued, so
    /// registering it would leak an entry nothing can claim or evict.
    @Test("ids that yield no canonical URL are neither registered nor enqueued")
    func unbuildableIDsAreDroppedEntirely() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: ["", "nope"],
            appendTarget: .playlist(5),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 0)
        #expect(harness.queueDouble.enqueuedURLs.isEmpty)
    }

    /// The shortfall must be measured against the URLs that were actually ENQUEUED, not
    /// against the whole request. An id the normalizer refused was never sent to the
    /// queue, so it cannot be missing from the queue's answer — counting it turns a
    /// one-for-one success into a phantom cap refusal that evicts a sound registration.
    @Test("an unbuildable id beside a valid one does not fake a shortfall")
    func anUnbuildableIDDoesNotFakeAShortfall() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        harness.queueDouble.outcome = EnqueueOutcome(added: 1, duplicatesDropped: 0)

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first, "nope"],
            appendTarget: .playlist(5),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 1)
        #expect(harness.registry.claimRegistrations(videoID: ChatDownloadFixtureIDs.first)
            == [SuggestionDownloadRegistration(target: .playlist(5), profileId: ProfileRecord.guestID)])
        #expect(harness.activeToastText == nil)
    }

    @Test("an empty request touches nothing at all")
    func anEmptyRequestTouchesNothing() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [],
            appendTarget: .playlist(5),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatDownloadWork()

        #expect(harness.registry.count == 0)
        #expect(harness.queueDouble.enqueuedURLs.isEmpty)
        #expect(harness.activeToastText == nil)
    }

    /// A batch whose files the gate refuses says the guidance sentence once, however
    /// many files tripped it.
    @Test("a gate-failure batch raises exactly one guidance toast")
    func aGateFailureBatchRaisesOneGuidanceToast() async throws {
        // Auto-import OFF and a destination under no library root: the gate refuses.
        let harness = try ChatDownloadWiringHarness(autoImport: false)
        defer { harness.cleanUp() }
        let playlistId = try harness.makePlaylist(named: "Gated")
        for videoID in [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second] {
            harness.registry.register(
                videoID: videoID,
                target: .playlist(playlistId),
                profileId: ProfileRecord.guestID
            )
            let file = try harness.importedTrack(named: "Gated [\(videoID)].m4a")
            try await harness.finish(harness.item(videoID), at: file.url)
        }

        #expect(harness.scanner.fileScanCount == 0)
        #expect(harness.activeToastText == String(localized: MacAMPStrings.chatDownloadGateGuidanceToast))
        #expect(try await harness.membership(playlistId: playlistId).isEmpty)
    }

    static func proposal(profileId: Int64) -> AIProposal {
        AIProposal(
            profileId: profileId,
            kind: .createPlaylist(CreatePlaylistRequest(
                draft: PlaylistDraft(
                    entries: [],
                    nameHint: MixNameHint(sourceKind: .rulesResult, trackCount: 0)
                ),
                name: "Proposed"
            ))
        )
    }
}
