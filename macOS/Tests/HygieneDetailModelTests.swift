// HygieneDetailModelTests — the four behaviours the library-health sheet's UITest
// cannot attribute on its own.
//
// A UITest failure there is AMBIGUOUS: "the Review button was missing" and "Apply
// changed the wrong playlist" each have two possible causes — a broken mapping, or a
// broken query. These assert the mapping half directly, with no database and no
// window, so a future UITest failure can be attributed immediately.
//
// The specific bugs they guard:
//
//   * A row's accessibility identifier carries its index in the FINDINGS array, not
//     in its section. Numbering per section would make `assistant.hygiene.finding.0`
//     ambiguous across three sections.
//   * "Nothing to change here" has to be the mapping's own answer, not a guess: a
//     duplicate no playlist lists twice and a gap with no artist to copy both map to
//     no proposal, and the row must say so instead of offering a dead button.
//   * A section's batch is ONE call over every finding, which is not the same as
//     concatenating the per-row results — `hygieneProposals` merges gap patches, and
//     losing that merge would raise one file-write confirmation per track.
//   * `.organize` writes a COMPLETE membership, so two proposals derived from the
//     same pre-change playlist do not compose: applying the second undoes the first.
import Foundation
@testable import MacAMP
import Services
import Testing
import ViewModels

@MainActor
@Suite("HygieneDetailModelTests")
struct HygieneDetailModelTests {
    private static let profileId: Int64 = 1

    // MARK: Sections

    @Test("the three finding categories split into three sections, in a fixed order")
    func findingsSplitIntoOrderedSections() {
        let sections = HygieneDetailModel.sections(
            for: [
                .duplicate(HygieneFixtures.duplicateGroup(playlistId: 1)),
                .genreCluster(HygieneFixtures.genreCluster()),
                .metadataGap(HygieneFixtures.gap(10, artist: "Gap Artist")),
            ],
            profileId: Self.profileId
        )

        #expect(sections.map(\.kind) == [.duplicates, .genres, .gaps])
        #expect(sections.map(\.rows.count) == [1, 1, 1])
    }

    @Test("a category with no findings gets no section at all")
    func emptyCategoriesAreOmitted() {
        let sections = HygieneDetailModel.sections(
            for: [.metadataGap(HygieneFixtures.gap(10, artist: "Gap Artist"))],
            profileId: Self.profileId
        )

        #expect(sections.map(\.kind) == [.gaps])
    }

    /// The row's index is what the accessibility identifier carries, so it has to be
    /// the position in the FINDINGS array — stable across sections and unique.
    @Test("a row's index is its position in the findings array, not in its section")
    func rowIndexIsTheFindingPosition() throws {
        let sections = HygieneDetailModel.sections(
            for: [
                .metadataGap(HygieneFixtures.gap(10, artist: "Gap Artist")),
                .duplicate(HygieneFixtures.duplicateGroup(playlistId: 1)),
                .metadataGap(HygieneFixtures.gap(11, artist: "Gap Artist")),
            ],
            profileId: Self.profileId
        )

        let duplicates = try #require(sections.first { $0.kind == .duplicates })
        let gaps = try #require(sections.first { $0.kind == .gaps })
        #expect(duplicates.rows.map(\.index) == [1])
        #expect(gaps.rows.map(\.index) == [0, 2])
    }

    @Test("a finding the mapping produces nothing for is listed, but is not actionable")
    func unactionableFindingsAreListedWithoutAProposal() throws {
        let sections = HygieneDetailModel.sections(
            for: [
                .duplicate(HygieneFixtures.duplicateGroup(playlistId: nil)),
                .metadataGap(HygieneFixtures.gap(10, artist: nil)),
            ],
            profileId: Self.profileId
        )

        #expect(sections.map(\.kind) == [.duplicates, .gaps])
        for section in sections {
            let row = try #require(section.rows.first)
            #expect(row.proposals.isEmpty)
            #expect(!row.isActionable)
            #expect(!section.isActionable)
        }
    }

    /// Concatenating the per-row proposals would produce one tag change-set per
    /// track, and therefore one "write files to disk?" confirmation per track.
    @Test("a gaps section batches every gap into ONE tag change-set")
    func gapsSectionMergesIntoOneBatch() throws {
        let sections = HygieneDetailModel.sections(
            for: [
                .metadataGap(HygieneFixtures.gap(10, artist: "Gap Artist")),
                .metadataGap(HygieneFixtures.gap(11, artist: "Gap Artist")),
                .metadataGap(HygieneFixtures.gap(12, artist: "Gap Artist")),
            ],
            profileId: Self.profileId
        )

        let gaps = try #require(sections.first { $0.kind == .gaps })
        #expect(gaps.rows.count == 3)
        #expect(gaps.rows.allSatisfy { $0.proposals.count == 1 })
        #expect(gaps.batch.count == 1)
        let batched = try #require(gaps.batch.first)
        #expect(batched.affectedCount == 3)
        #expect(batched.requiresBatchConfirmation)
    }

    // MARK: Deconfliction

    @Test("two organize proposals for one playlist are cut down to the first")
    func conflictingMembershipRewritesAreDropped() {
        let first = HygieneFixtures.organize(playlistId: 7, proposedTrackIds: [1, 2])
        let second = HygieneFixtures.organize(playlistId: 7, proposedTrackIds: [1, 3])
        let other = HygieneFixtures.organize(playlistId: 8, proposedTrackIds: [4])

        let kept = HygieneDetailModel.deconflicted([first, second, other])

        #expect(kept.map(\.id) == [first.id, other.id])
    }

    @Test("deconfliction leaves every non-organize kind alone")
    func deconflictionOnlyTouchesOrganize() {
        let tags = AssistantViewModel.hygieneProposals(
            for: [
                .metadataGap(HygieneFixtures.gap(10, artist: "Gap Artist")),
                .genreCluster(HygieneFixtures.genreCluster()),
            ],
            profileId: Self.profileId
        )

        #expect(HygieneDetailModel.deconflicted(tags).count == tags.count)
    }

    // MARK: Review queue

    @Test("enqueue files every proposal and hands them back head first")
    func enqueueFilesAndOrdersTheBatch() {
        let model = HygieneDetailModel()
        let store = ProposalStore()
        let first = HygieneFixtures.organize(playlistId: 7, proposedTrackIds: [1])
        let second = HygieneFixtures.organize(playlistId: 8, proposedTrackIds: [2])

        model.enqueue([first, second], into: store)

        #expect(store.proposals.map(\.id) == [first.id, second.id])
        #expect(model.hasPendingReview)
        #expect(model.dequeue()?.id == first.id)
        #expect(model.dequeue()?.id == second.id)
        #expect(model.dequeue() == nil)
        #expect(!model.hasPendingReview)
    }

    /// The sheet has no other way to learn that a proposal was applied: the preview
    /// reports nothing back, and `apply` is the only thing that removes a proposal
    /// from the store.
    @Test("consumeDidApply reports true only after a filed proposal has left the store")
    func consumeDidApplyDetectsAnApply() {
        let model = HygieneDetailModel()
        let store = ProposalStore()
        let proposal = HygieneFixtures.organize(playlistId: 7, proposedTrackIds: [1])

        model.enqueue([proposal], into: store)
        #expect(!model.consumeDidApply(from: store))

        model.enqueue([proposal], into: store)
        store.remove(proposal)
        #expect(model.consumeDidApply(from: store))
        // One-shot: the answer is a "reload now", not a standing flag.
        #expect(!model.consumeDidApply(from: store))
    }

    // MARK: Loading

    @Test("a switched-off bundle loads to an empty sheet rather than an error")
    func nilProviderLoadsEmpty() async {
        let model = HygieneDetailModel()

        await model.load(profileId: Self.profileId, hygiene: nil)

        #expect(model.isEmpty)
        #expect(model.didLoad)
        #expect(!model.isLoading)
    }

    @Test("a failing pass loads to an empty sheet rather than an error")
    func failingPassLoadsEmpty() async {
        let model = HygieneDetailModel()

        await model.load(profileId: Self.profileId, hygiene: StubHygieneService(shouldFail: true))

        #expect(model.isEmpty)
        #expect(model.didLoad)
    }

    @Test("a pass with findings loads them into their sections")
    func loadPopulatesSections() async {
        let model = HygieneDetailModel()
        let service = StubHygieneService(findings: [
            .duplicate(HygieneFixtures.duplicateGroup(playlistId: 1)),
            .metadataGap(HygieneFixtures.gap(10, artist: "Gap Artist")),
        ])

        await model.load(profileId: Self.profileId, hygiene: service)

        #expect(!model.isEmpty)
        #expect(model.sections.map(\.kind) == [.duplicates, .gaps])
    }
}
