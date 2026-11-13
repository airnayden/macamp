// ChatDownloadRebuildTests — the three seams must survive the AI graph being replaced,
// and the registry must not survive it holding proposals nobody can resolve.
//
// `makeAI` mints a FRESH `ProposalStore`, a fresh assistant and a fresh chat on every
// toggle flip, provider change and profile switch, and answers `nil` outright while
// Intelligence is off. So a one-shot wiring from `connectDownloads` is wrong twice over:
// it never installs at all on the common "launch with Intelligence off, enable later"
// path (`connectAI` runs BEFORE `connectDownloads`), and it silently loses all three
// seams on every flip afterwards.
//
// Both rebuild edges are driven here, because they fail differently:
//
//   * ON→OFF is where `makeAI` returns `nil`. A nil-guarded eviction would skip exactly
//     the edge the hygiene exists for — the transcript is gone, no `reset()` ran, and the
//     old proposal UUIDs are unclaimable forever.
//   * OFF→ON / rescope is where the seams have to be re-installed onto the NEW graph. A
//     fresh registration plus an apply on the rebuilt graph must still flush its held
//     append.
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Chat download rebuild survival", .serialized)
@MainActor
struct ChatDownloadRebuildTests {
    // MARK: - Edge (i): Intelligence ON → OFF

    @Test("turning Intelligence OFF evicts pending-proposal registrations and held appends")
    func turningIntelligenceOffEvictsPendingProposalState() throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: true)
        defer { harness.cleanUp() }
        let proposalId = UUID()
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .pendingProposal(proposalId),
            profileId: ProfileRecord.guestID
        )
        harness.registry.hold(trackId: 99, forProposal: proposalId)

        harness.settings.intelligenceEnabled = false
        harness.environment.rebuildAI(settings: harness.settings)

        #expect(harness.environment.intelligence == nil)
        #expect(harness.registry.count == 0)
        #expect(harness.registry.heldTrackIds(forProposal: proposalId).isEmpty)
    }

    /// …and it must be `evictAllPendingProposals()`, not `removeAll()`: a download
    /// already bound for a REAL playlist is still in flight and still correct.
    @Test("a rebuild leaves in-flight playlist registrations alone")
    func aRebuildSparesRealPlaylistRegistrations() throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: true)
        defer { harness.cleanUp() }
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.second,
            target: .playlist(8),
            profileId: ProfileRecord.guestID
        )

        harness.settings.intelligenceEnabled = false
        harness.environment.rebuildAI(settings: harness.settings)

        #expect(harness.registry.claimRegistrations(videoID: ChatDownloadFixtureIDs.second)
            == [SuggestionDownloadRegistration(target: .playlist(8), profileId: ProfileRecord.guestID)])
    }

    // MARK: - Edge (ii): OFF → ON, and a profile rescope

    @Test("turning Intelligence back ON evicts the old pending state AND installs live seams")
    func turningIntelligenceOnRewiresOntoTheNewGraph() async throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: false)
        defer { harness.cleanUp() }
        let staleProposal = UUID()
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.second,
            target: .pendingProposal(staleProposal),
            profileId: ProfileRecord.guestID
        )

        harness.settings.intelligenceEnabled = true
        harness.environment.rebuildAI(settings: harness.settings)

        #expect(harness.registry.count == 0)
        try await Self.assertSeamsAreLive(harness)
    }

    @Test("a profile rescope keeps the seams live on the rebuilt graph")
    func aRescopeKeepsTheSeamsLive() async throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: true)
        defer { harness.cleanUp() }

        harness.environment.rescopeAI(settings: harness.settings)

        try await Self.assertSeamsAreLive(harness)
    }

    /// The chat-reset seam is the third one, and it is the one that has to be re-armed on
    /// a view model that did not exist when `connectDownloads` ran.
    @Test("the chat-reset seam on a rebuilt graph still clears the registry")
    func theResetSeamSurvivesARebuild() throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: true)
        defer { harness.cleanUp() }
        harness.environment.rebuildAI(settings: harness.settings)
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(3),
            profileId: ProfileRecord.guestID
        )

        harness.environment.intelligence?.chat.reset()

        #expect(harness.registry.count == 0)
    }

    /// Discarding a proposal on a rebuilt graph must still drop everything aimed at it.
    @Test("the discard seam on a rebuilt graph still evicts")
    func theDiscardSeamSurvivesARebuild() throws {
        let harness = try ChatDownloadWiringHarness(intelligenceEnabled: true)
        defer { harness.cleanUp() }
        harness.environment.rebuildAI(settings: harness.settings)
        let assistant = try #require(harness.environment.intelligence?.assistant)
        let proposalId = UUID()
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .pendingProposal(proposalId),
            profileId: ProfileRecord.guestID
        )
        harness.registry.hold(trackId: 5, forProposal: proposalId)

        assistant.onProposalDiscarded?(proposalId)

        #expect(harness.registry.count == 0)
        #expect(harness.registry.heldTrackIds(forProposal: proposalId).isEmpty)
    }

    /// The full round trip on the NEW graph: a fresh registration, a finished download
    /// that parks its track on the proposal, then the apply seam flushing it into the
    /// playlist the proposal became. This is the assertion that fails under a one-shot
    /// wiring while every piece-level test still passes.
    private static func assertSeamsAreLive(_ harness: ChatDownloadWiringHarness) async throws {
        let assistant = try #require(harness.environment.intelligence?.assistant)
        let playlistId = try harness.makePlaylist(named: "Rebuilt")
        let file = try harness.importedTrack(named: "Rebuilt [\(ChatDownloadFixtureIDs.first)].m4a")
        let proposalId = UUID()
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .pendingProposal(proposalId),
            profileId: ProfileRecord.guestID
        )

        try await harness.finish(harness.item(ChatDownloadFixtureIDs.first), at: file.url)
        #expect(harness.registry.heldTrackIds(forProposal: proposalId) == [file.trackId])

        assistant.onPlaylistCreatedFromProposal?(proposalId, playlistId)
        await harness.environment.drainChatDownloadWork()

        #expect(try await harness.membership(playlistId: playlistId) == [file.trackId])
    }
}
