import Foundation
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

/// Todo 17 acceptance: `submit` walks the FM → heuristic → deterministic ladder,
/// resolves the spec through the READ-ONLY rule preview, files a proposal, and
/// writes absolutely nothing on the way.
@MainActor
struct AssistantViewModelSubmitTests {
    // MARK: End to end

    @Test func aRequestBecomesAProposalWhoseApplyWritesTheDraftsExactOrder() async throws {
        let harness = SubmitHarness()
        harness.fallback.setSpec(PlaylistQuerySpec(
            genres: ["Rock"],
            yearRange: SmartPlaylistRange(lower: 1990, upper: 1999),
            moodTags: [.energetic]
        ))
        harness.smartPlaylists.configure { $0.previewTrackIds = [42, 7, 19] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([42, 19, 7]))

        let submitted = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 2)
        let proposal = try #require(submitted)

        #expect(harness.viewModel.lastError == nil)
        #expect(harness.playlists.recording.mutationCount == 0)
        #expect(harness.store.proposals.map(\.id) == [proposal.id])

        harness.store.add(proposal)
        try await harness.viewModel.apply(proposal)

        let recording = harness.playlists.recording
        #expect(recording.createdNames == ["upbeat 90s rock"])
        #expect(recording.reorderCalls.first?.orderedTrackIds == [42, 19, 7])
        #expect(harness.store.isEmpty)
    }

    @Test func theResolvedSpecFansOutOverGenresAndFeedsTheMergedPoolToTheMix() async throws {
        let harness = SubmitHarness()
        harness.fallback.setSpec(PlaylistQuerySpec(
            genres: ["Rock", "Metal"],
            yearRange: SmartPlaylistRange(lower: 1990, upper: 1999)
        ))
        harness.smartPlaylists.configure { $0.previewTrackIds = [42, 7] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([42, 7]))

        _ = await harness.viewModel.submit(text: "90s rock or metal", profileId: 2)

        let previews = harness.smartPlaylists.recording.previewRequests
        #expect(previews.count == 2)
        #expect(previews.allSatisfy { $0.profileId == 2 })
        #expect(previews.allSatisfy { $0.rules.match == .all })
        #expect(previews.map(\.rules.predicates).map(SubmitHarness.genreNames) == [["Rock"], ["Metal"]])
        #expect(previews.allSatisfy { $0.rules.predicates.contains(.metadata(.year(
            range: SmartPlaylistRange(lower: 1990, upper: 1999)
        ))) })

        let generated = harness.mixGenerator.recording.specs.first
        let spec = try #require(generated)
        #expect(spec.source == .rulesResult(trackIds: [42, 7]))
        #expect(spec.profileId == 2)
    }

    /// `evaluate` materialises `playlistTrack` rows; a proposal-generation path must
    /// never call it. This is the assertion that keeps that true.
    @Test func generationNeverEvaluatesASmartPlaylist() async {
        let harness = SubmitHarness()
        harness.smartPlaylists.configure { $0.previewTrackIds = [1, 2] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1, 2]))

        _ = await harness.viewModel.submit(text: "anything", profileId: 1)

        #expect(harness.smartPlaylists.recording.evaluateRequests.isEmpty)
        #expect(harness.smartPlaylists.recording.setRulesRequests.isEmpty)
        #expect(harness.playlists.recording.mutationCount == 0)
    }

    // MARK: The ladder

    @Test func theModelTierIsPreferredWhenItIsInjectedAndAvailable() async {
        let model = FakeAssistantQueryParser(spec: PlaylistQuerySpec(genres: ["Jazz"]))
        let harness = SubmitHarness(modelParser: model)
        harness.fallback.setSpec(PlaylistQuerySpec(genres: ["Rock"]))
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))

        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(model.recording.requests.map(\.text) == ["some jazz"])
        #expect(harness.fallback.recording.requests.isEmpty)
        #expect(SubmitHarness.genreNames(harness.smartPlaylists.recording.previewRequests[0].rules.predicates)
            == ["Jazz"])
    }

    @Test func aModelFailureFallsThroughToTheHeuristicTier() async {
        let model = FakeAssistantQueryParser()
        model.setFailure()
        let harness = SubmitHarness(modelParser: model)
        harness.fallback.setSpec(PlaylistQuerySpec(genres: ["Rock"]))
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal != nil)
        #expect(model.recording.requests.count == 1)
        #expect(harness.fallback.recording.requests.map(\.text) == ["upbeat 90s rock"])
        #expect(SubmitHarness.genreNames(harness.smartPlaylists.recording.previewRequests[0].rules.predicates)
            == ["Rock"])
    }

    /// Every unavailability reason EXCEPT the listener's own switch degrades to the
    /// heuristic tier rather than refusing — that tier exists precisely for machines
    /// where the model does not.
    @Test func anIneligibleDeviceStillGetsAProposalFromTheHeuristicTier() async {
        let model = FakeAssistantQueryParser(spec: PlaylistQuerySpec(genres: ["Jazz"]))
        let harness = SubmitHarness(
            modelParser: model,
            availability: { .unavailable(reason: .deviceNotEligible) }
        )
        harness.fallback.setSpec(PlaylistQuerySpec(genres: ["Rock"]))
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal != nil)
        #expect(model.recording.requests.isEmpty)
        #expect(harness.fallback.recording.requests.count == 1)
        #expect(harness.viewModel.availability == .unavailable(reason: .deviceNotEligible))
    }

    @Test func theListenersOwnSwitchStopsEverythingBeforeAnyParserRuns() async {
        let model = FakeAssistantQueryParser()
        let harness = SubmitHarness(
            modelParser: model,
            availability: { .unavailable(reason: .intelligenceDisabled) }
        )

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal == nil)
        #expect(harness.viewModel.lastError == .assistantUnavailable(reason: .intelligenceDisabled))
        #expect(model.recording.requests.isEmpty)
        #expect(harness.fallback.recording.requests.isEmpty)
        #expect(harness.smartPlaylists.recording.previewRequests.isEmpty)
        #expect(harness.store.isEmpty)
    }

    @Test func aParserThatThrowsOnEveryTierStillProducesTheDeterministicDefault() async throws {
        let model = FakeAssistantQueryParser()
        model.setFailure()
        let harness = SubmitHarness(modelParser: model)
        harness.fallback.setFailure()
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))

        let submitted = await harness.viewModel.submit(text: "???", profileId: 1)
        let proposal = try #require(submitted)

        let predicates = harness.smartPlaylists.recording.previewRequests[0].rules.predicates
        #expect(predicates.contains(.recency(.playedWithin(
            days: AssistantQueryTranslation.recentlyPlayedWindowDays
        ))))
        guard case let .createPlaylist(request) = proposal.kind else {
            Issue.record("expected a create proposal")
            return
        }
        #expect(request.querySpec?.lowConfidence == true)
    }

    // MARK: Empty and busy paths

    @Test func anEmptyPoolProducesNoProposalAndATypedReason() async {
        let harness = SubmitHarness()
        harness.smartPlaylists.configure { $0.previewTrackIds = [] }

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal == nil)
        #expect(harness.viewModel.lastError == .noMatchingTracks)
        #expect(harness.mixGenerator.recording.specs.isEmpty)
        #expect(harness.store.isEmpty)
    }

    @Test func blankTextIsIgnoredWithoutTouchingAnySeam() async {
        let harness = SubmitHarness()

        let proposal = await harness.viewModel.submit(text: "   \n ", profileId: 1)

        #expect(proposal == nil)
        #expect(harness.fallback.recording.requests.isEmpty)
        #expect(harness.smartPlaylists.recording.previewRequests.isEmpty)
    }

    /// A second request while one is in flight is REJECTED, not queued — and it is
    /// not an error, so it must never set ``AssistantViewModel/lastError``.
    @Test func aSecondRequestWhileOneIsInFlightIsRejectedWithoutAnError() async {
        let gate = GatedQueryParser()
        let harness = SubmitHarness(fallback: gate)
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))

        let inFlight = Task { await harness.viewModel.submit(text: "first", profileId: 1) }
        await gate.waitUntilStarted()
        #expect(harness.viewModel.isBusy)

        let rejected = await harness.viewModel.submit(text: "second", profileId: 1)
        #expect(rejected == nil)
        #expect(harness.viewModel.lastError == nil)

        gate.release()
        let first = await inFlight.value

        #expect(first != nil)
        #expect(gate.requestedTexts == ["first"])
        #expect(!harness.viewModel.isBusy)
    }
}
