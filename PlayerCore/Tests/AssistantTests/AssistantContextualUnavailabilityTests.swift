// AssistantContextualUnavailabilityTests — every `nil` a contextual proposer
// returns names its own reason.
//
// The regression these pin: `proposeEnergyReorder` returned `nil` for five
// structurally different situations and the shell had no way to tell them apart,
// so a playlist that was too long, one that was barely analysed and one already in
// energy order all produced the same "Nothing to suggest here yet". Two of those
// three are actionable and the third is not, and the listener could not tell which
// they had.
//
// Asserted through ``AssistantViewModel/lastUnavailability`` rather than through a
// changed return type, so `lastError` keeps meaning "this FAILED" and the two stay
// orthogonal — the same split ``AssistantTierDiagnostic`` already has.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

@MainActor
@Suite("AssistantContextualUnavailabilityTests")
struct AssistantContextualUnavailabilityTests {
    @Test("a selection shorter than the arc minimum reports selectionTooShort")
    func selectionShorterThanTheArcMinimumReportsTooShort() async {
        let harness = SubmitHarness()

        let proposal = await harness.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: [10, 11],
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(harness.viewModel.lastUnavailability == .selectionTooShort(minimum: MixRanking.minimumArcLength))
        #expect(harness.viewModel.lastError == nil)
    }

    /// Repeats collapse BEFORE the length test, so a three-entry playlist listing
    /// one track three times is genuinely too short — and must say so rather than
    /// reporting whatever the generator would have made of a one-track pool.
    @Test("repeats collapse before the length test")
    func repeatsCollapseBeforeTheLengthTest() async {
        let harness = SubmitHarness()

        let proposal = await harness.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: [10, 10, 10],
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(harness.viewModel.lastUnavailability == .selectionTooShort(minimum: MixRanking.minimumArcLength))
        #expect(harness.mixGenerator.recording.specs.isEmpty, "a refused selection must not reach the generator")
    }

    @Test("a selection past the ranking ceiling reports selectionTooLong")
    func selectionPastTheRankingCeilingReportsTooLong() async {
        let harness = SubmitHarness()
        let ids = Array(1 ... Int64(MixSpec.maxTargetCount + 1))

        let proposal = await harness.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: ids,
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(harness.viewModel.lastUnavailability == .selectionTooLong(limit: MixSpec.maxTargetCount))
        #expect(harness.mixGenerator.recording.specs.isEmpty)
    }

    /// The pipeline declining the arc can only mean coverage: length is guarded
    /// before the call and `energyArc: true` is always requested.
    @Test("a draft the pipeline refused to arc reports insufficientAnalysis")
    func aDraftTheGeneratorRefusedToArcReportsInsufficientAnalysis() async {
        let harness = SubmitHarness()
        harness.mixGenerator.setDraft(Self.draft([10, 11, 12], arcApplied: false))

        let proposal = await harness.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: [10, 11, 12],
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(
            harness.viewModel.lastUnavailability == .insufficientAnalysis(required: MixRanking.energyArcCoverage)
        )
        #expect(harness.viewModel.lastError == nil, "an unanalysed library is not a failure")
    }

    @Test("an arc that moves nothing reports nothingToChange")
    func anArcThatMovesNothingReportsNothingToChange() async {
        let harness = SubmitHarness()
        harness.mixGenerator.setDraft(Self.draft([10, 11, 12], arcApplied: true))

        let proposal = await harness.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: [10, 11, 12],
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(harness.viewModel.lastUnavailability == .nothingToChange)
    }

    /// The happy path must CLEAR the reason, or the shell would report the previous
    /// refusal alongside a perfectly good proposal.
    @Test("a filed proposal leaves no unavailability behind")
    func aFiledProposalLeavesNoUnavailabilityBehind() async {
        let harness = SubmitHarness()
        _ = await harness.viewModel.proposeEnergyReorder(playlistId: 1, orderedTrackIds: [10, 11], profileId: 1)
        #expect(harness.viewModel.lastUnavailability != nil)
        harness.mixGenerator.setDraft(Self.draft([12, 10, 11], arcApplied: true))

        let proposal = await harness.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: [10, 11, 12],
            profileId: 1
        )

        #expect(proposal != nil)
        #expect(harness.viewModel.lastUnavailability == nil)
    }

    /// The reason channel belongs to EVERY contextual proposer, not just the energy
    /// reorder — a channel one caller filled would be an ad-hoc side channel.
    @Test("a playlist with nothing listed twice reports nothingToChange")
    func aPlaylistWithNothingListedTwiceReportsNothingToChange() {
        let harness = SubmitHarness()

        let proposal = harness.viewModel.proposeMembershipCleanup(
            playlistId: 1,
            tracks: [],
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(harness.viewModel.lastUnavailability == .nothingToChange)
    }

    @Test("a view model composed without a naming tier reports backendUnavailable")
    func aViewModelWithoutANamingTierReportsBackendUnavailable() async {
        let harness = SubmitHarness()

        let proposal = await harness.viewModel.proposeRename(
            playlistId: 1,
            currentName: "Evening",
            context: PlaylistNamingContext(trackCount: 4),
            profileId: 1
        )

        #expect(proposal == nil)
        #expect(harness.viewModel.lastUnavailability == .backendUnavailable)
    }
}

private extension AssistantContextualUnavailabilityTests {
    static func draft(_ trackIds: [Int64], arcApplied: Bool) -> PlaylistDraft {
        PlaylistDraft(
            entries: trackIds.map { MixDraftEntry(trackId: $0, provenance: .rulesResult, score: 1) },
            nameHint: MixNameHint(sourceKind: .rulesResult, trackCount: trackIds.count),
            energyArcApplied: arcApplied
        )
    }
}
