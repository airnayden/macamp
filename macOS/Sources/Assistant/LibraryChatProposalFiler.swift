// LibraryChatProposalFiler — the production witness for W1's one non-read seam.
//
// `propose_playlist` FILES; it does not write (W1 note 7). ``ToolboxProposalFiling``
// is deliberately the only requirement the toolbox cannot satisfy on its own, and
// this is the composition root conforming it — over the SAME ``ProposalStore`` the
// request field and `ProposalPreviewSheet` already use, so a playlist the assistant
// proposed in conversation is reviewed, ticked and applied through the one existing
// safety gate rather than a second one built for chat.
//
// ── WHY `@MainActor` CAN WITNESS A `Sendable` PROTOCOL ────────────────────────
//
// `fileCreatePlaylistProposal` is `async` in the protocol precisely so an
// actor-isolated method may witness it (recorded in the W1 learnings). `ProposalStore`
// is `@MainActor`, so this type is too, and the toolbox reaches it with an `await`
// from whatever executor the tool ran on.
//
// ── THE DRAIN IS HOW A TURN LEARNS WHAT IT FILED ──────────────────────────────
//
// The tool's rendered text is model-facing prose and carries no identifier, so a
// surface cannot recover the proposal by parsing events. `drain()` hands the ids to
// the chat view model at the end of a turn, in filing order, and clears them — an id
// is therefore attributed to exactly one message and never to the next one.
import Foundation
import Services
import ViewModels

/// Files `propose_playlist`'s output into the shell's proposal store.
@MainActor
final class LibraryChatProposalFiler: ToolboxProposalFiling {
    private let store: ProposalStore
    private var filed: [UUID] = []

    init(store: ProposalStore) {
        self.store = store
    }

    func fileCreatePlaylistProposal(_ proposal: ToolboxPlaylistProposal) async throws -> UUID {
        let filedProposal = Self.proposal(from: proposal)
        store.add(filedProposal)
        filed.append(filedProposal.id)
        return filedProposal.id
    }

    /// The ids filed since the previous call, oldest first.
    func drain() -> [UUID] {
        defer { filed.removeAll() }
        return filed
    }
}

private extension LibraryChatProposalFiler {
    /// A toolbox proposal as the review surface's own value type.
    ///
    /// The draft carries only what this layer HONESTLY knows — ids, in the order the
    /// model asked for them — which is the same restraint
    /// ``AssistantViewModel/createRequest(draft:spec:request:locale:)`` shows when it
    /// leaves the ranked aggregate lists empty rather than inventing counts. Scores
    /// descend so the draft's order is the model's order; no reordering happens here.
    static func proposal(from proposal: ToolboxPlaylistProposal) -> AIProposal {
        let count = proposal.trackIds.count
        let entries = proposal.trackIds.enumerated().map { index, trackId in
            MixDraftEntry(trackId: trackId, provenance: .rulesResult, score: Double(count - index))
        }
        let draft = PlaylistDraft(
            entries: entries,
            nameHint: MixNameHint(sourceKind: .rulesResult, trackCount: count)
        )
        return AIProposal(
            profileId: proposal.profileId,
            kind: .createPlaylist(CreatePlaylistRequest(
                draft: draft,
                name: proposal.name,
                summary: proposal.summary
            ))
        )
    }
}
