// HygieneDetailModel — what the library-health sheet shows, and what pressing
// Review actually hands to the preview.
//
// A projection, not a store: the findings are re-derived every time the sheet opens
// and NEVER persisted, the same discipline ``AssistantFeedModel``,
// `KaraokeReadyStore` and `KaraokeQueueStore` follow. Nothing in this file can reach
// a repository or a writer — it maps findings to ``AIProposal``s, and only
// `AssistantViewModel.apply` ever writes.
//
// ── THE ROWS CARRY THEIR OWN PROPOSALS ─────────────────────────────────────────
//
// Mapping happens once, at load, and the result is stored on the row. Two reasons,
// both load-bearing:
//
//   * A proposal's id is minted at construction and must stay stable, or pressing
//     Review twice would file two copies of the same change into ``ProposalStore``.
//     Mapping in `body` — or lazily into a cache — would either re-mint the id or
//     mutate observable state during a view update.
//   * "This finding is only worth reading" is exactly "the mapping produced nothing"
//     (a duplicate no playlist lists twice, a gap with no artist to copy). Computing
//     it up front is what lets the row say so instead of offering a dead button.
//
// ── A SECTION IS A BATCH, NOT A LOOP ───────────────────────────────────────────
//
// ``Section/batch`` is the mapping run over EVERY row's finding in one call, which
// is not the same as concatenating the per-row results: `hygieneProposals` merges
// metadata-gap patches into a single tag change-set, so Review All on three hundred
// untagged tracks raises one confirmation instead of three hundred.
import Foundation
import Observation
import Services
import ViewModels

@MainActor
@Observable
final class HygieneDetailModel {
    /// Ceiling on the pass this sheet lists. The same number ``AssistantFeedModel``
    /// counts with, so the card and the sheet can never disagree.
    static let limit = LibraryHygieneService.maxFindings

    /// The three finding categories, in the order the sheet renders them.
    enum SectionKind: String, CaseIterable {
        case duplicates
        case genres
        case gaps
    }

    /// One finding, with the change it is actionable as.
    struct Row: Identifiable {
        /// Position in the findings array — the number in this row's accessibility
        /// identifier, so a test can address a row without knowing its section.
        let index: Int
        let finding: HygieneFinding
        /// What accepting THIS finding would do. Empty ⇒ nothing to change.
        let proposals: [AIProposal]

        var id: Int {
            index
        }

        var isActionable: Bool {
            !proposals.isEmpty
        }
    }

    /// One category of findings, with the whole category as a single batch.
    struct Section: Identifiable {
        let kind: SectionKind
        let rows: [Row]
        /// Every row's finding mapped in ONE call — see the file header.
        let batch: [AIProposal]

        var id: String {
            kind.rawValue
        }

        var isActionable: Bool {
            !batch.isEmpty
        }
    }

    private(set) var sections: [Section] = []
    private(set) var isLoading = false
    /// `false` until the first pass finishes, so the sheet can tell "still looking"
    /// from "looked, and found nothing".
    private(set) var didLoad = false

    /// Proposals handed to the preview, head first. Runtime-only, never persisted.
    @ObservationIgnored private var queue: [AIProposal] = []
    /// Ids filed since the last drain, so the sheet can tell whether anything was
    /// actually applied without the preview having to report back.
    @ObservationIgnored private var reviewedIds: Set<UUID> = []

    var isEmpty: Bool {
        sections.isEmpty
    }

    var hasPendingReview: Bool {
        !queue.isEmpty
    }
}

// MARK: - Loading

extension HygieneDetailModel {
    /// Runs the hygiene pass and rebuilds the sections.
    ///
    /// A `nil` provider is the bundle-off case and resolves to an empty list rather
    /// than an error: the card that opens this sheet is itself gated on the bundle,
    /// so reaching here with no provider means the switch flipped mid-visit.
    func load(profileId: Int64, hygiene: (any LibraryHygieneProviding)?) async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }
        guard let hygiene else {
            apply(findings: [], profileId: profileId)
            return
        }
        let findings = try? await hygiene.findings(profileId: profileId, limit: Self.limit)
        apply(findings: findings ?? [], profileId: profileId)
    }
}

// MARK: - Review queue

extension HygieneDetailModel {
    /// Files `proposals` and queues them for review, head first.
    ///
    /// Filing is what makes them applicable at all — `AssistantViewModel.apply`
    /// raises `unknownProposal` for anything the store has never seen. Filing is
    /// still inert: ``ProposalStore`` cannot reach a repository.
    func enqueue(_ proposals: [AIProposal], into store: ProposalStore) {
        let batch = Self.deconflicted(proposals)
        guard !batch.isEmpty else { return }
        for proposal in batch {
            store.add(proposal)
            reviewedIds.insert(proposal.id)
        }
        queue.append(contentsOf: batch)
    }

    /// The next proposal to show, or `nil` when the batch is exhausted.
    func dequeue() -> AIProposal? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Whether anything reviewed since the last call has left the store — which
    /// only `apply` does, so it means the library changed and the findings are stale.
    ///
    /// Consuming the set here is deliberate: the answer is a one-shot "reload now",
    /// and leaving the ids behind would make every later drain report stale again.
    func consumeDidApply(from store: ProposalStore) -> Bool {
        guard !reviewedIds.isEmpty else { return false }
        let applied = reviewedIds.contains { !store.contains(id: $0) }
        reviewedIds.removeAll()
        return applied
    }
}

// MARK: - Mapping

extension HygieneDetailModel {
    /// Drops any later proposal that rewrites a playlist an earlier one in the same
    /// batch already rewrites.
    ///
    /// `.organize` writes the COMPLETE membership, so two proposals derived from the
    /// same pre-change playlist would not compose — applying the second would undo
    /// the first's removal. Two duplicate groups inside one playlist is exactly that
    /// shape. The dropped fix is not lost: the sheet reloads after an apply, and the
    /// next pass derives it against the membership that now exists.
    static func deconflicted(_ proposals: [AIProposal]) -> [AIProposal] {
        var claimed = Set<Int64>()
        return proposals.filter { proposal in
            guard case let .organize(playlistId, _) = proposal.kind else { return true }
            return claimed.insert(playlistId).inserted
        }
    }

    /// The sections `findings` split into, empty categories omitted.
    static func sections(for findings: [HygieneFinding], profileId: Int64) -> [Section] {
        let rows = findings.enumerated().map { offset, finding in
            Row(
                index: offset,
                finding: finding,
                proposals: AssistantViewModel.hygieneProposals(for: [finding], profileId: profileId)
            )
        }
        return SectionKind.allCases.compactMap { kind in
            let matching = rows.filter { kind.matches($0.finding) }
            guard !matching.isEmpty else { return nil }
            return Section(
                kind: kind,
                rows: matching,
                batch: AssistantViewModel.hygieneProposals(
                    for: matching.map(\.finding),
                    profileId: profileId
                )
            )
        }
    }
}

extension HygieneDetailModel.SectionKind {
    /// Exhaustive with no `default:` — a fourth analyzer becomes a compile error
    /// here rather than a category of findings the sheet silently drops.
    func matches(_ finding: HygieneFinding) -> Bool {
        switch finding {
        case .duplicate: self == .duplicates
        case .genreCluster: self == .genres
        case .metadataGap: self == .gaps
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .duplicates: HygieneDetailStrings.duplicatesSection
        case .genres: HygieneDetailStrings.genresSection
        case .gaps: HygieneDetailStrings.gapsSection
        }
    }
}

private extension HygieneDetailModel {
    func apply(findings: [HygieneFinding], profileId: Int64) {
        sections = Self.sections(for: findings, profileId: profileId)
    }
}
