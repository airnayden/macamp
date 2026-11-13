// DiscardedProposalStore — the proposals a listener discarded, kept only so the card
// that offered one stays reachable.
//
// ── WHY A SECOND STORE AND NOT A FLAG ON THE FIRST ───────────────────────────
//
// ``ProposalStore`` holds what is PENDING, and discarding removes from it — which is
// correct: a discarded proposal must not sit in "Waiting for you", and nothing may
// apply it. But a chat turn's card resolves through that same store, so discarding
// also erased the only route back to a playlist the assistant had proposed. This
// holds the value itself, off to one side, so the card can re-offer it.
//
// Re-opening such a card RE-FILES the proposal (``AppEnvironment/restoreDiscardedProposal(_:)``)
// before the sheet is presented, because `AssistantViewModel.apply` refuses a handle
// the pending store does not hold.
//
// Discriminating discard from apply is the whole point: an APPLIED proposal is never
// recorded here, so its card disappears exactly as it did before — offering to
// re-create a playlist that now exists would be a second playlist.
//
// NEVER PERSISTED, like the store it shadows: it is emptied when the conversation is
// reset and dies with the process.
import Foundation
import Observation
import ViewModels

@MainActor
@Observable
final class DiscardedProposalStore {
    private(set) var proposals: [UUID: AIProposal] = [:]

    func record(_ proposal: AIProposal) {
        proposals[proposal.id] = proposal
    }

    func proposal(id: UUID) -> AIProposal? {
        proposals[id]
    }

    /// Drops one entry. A miss writes nothing — `@Observable` notifies on same-value
    /// writes, so an unguarded reassignment would invalidate every observing view for
    /// nothing (SKILL macOS UI perf rule 3).
    func forget(id: UUID) {
        guard proposals[id] != nil else { return }
        proposals[id] = nil
    }

    func removeAll() {
        guard !proposals.isEmpty else { return }
        proposals.removeAll()
    }
}

// MARK: - Putting one back

extension AppEnvironment {
    /// Re-files a discarded proposal so the review sheet opened from its card can apply
    /// it. A proposal that was never discarded is left exactly as it is.
    func restoreDiscardedProposal(_ proposal: AIProposal) {
        guard discardedProposals.proposal(id: proposal.id) != nil,
              let proposals = intelligence?.proposals
        else {
            return
        }
        proposals.add(proposal)
        discardedProposals.forget(id: proposal.id)
    }
}
