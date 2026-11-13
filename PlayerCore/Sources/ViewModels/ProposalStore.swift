// ProposalStore — the in-memory holding pen for un-applied ``AIProposal``s.
//
// NEVER PERSISTED. Not to GRDB, not to `UserDefaults`, not to a snapshot — the
// same discipline ``KaraokeQueueStore`` and ``KaraokeReadyStore`` follow, and for
// a stronger reason here: a proposal is a suggestion the listener has not agreed
// to, and a suggestion that survives a relaunch is a decision the app made on
// their behalf. This type imports no persistence machinery at all, so the rule is
// structural rather than a promise.
//
// It is also inert: nothing here can reach a repository, a writer or the
// filesystem. Adding a proposal has no side effect whatsoever;
// ``AssistantViewModel/apply(_:confirmedBatch:)`` is the only code that writes.
//
// This file imports only Foundation + Observation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import Observation

/// The pending proposals awaiting the listener's decision, oldest first.
@MainActor
@Observable
public final class ProposalStore {
    /// Pending proposals in the order they were produced. ``latest`` is the newest.
    public private(set) var proposals: [AIProposal] = []

    public init() {}

    /// The most recently added proposal, or `nil` when the store is empty.
    public var latest: AIProposal? {
        proposals.last
    }

    public var isEmpty: Bool {
        proposals.isEmpty
    }

    /// Adds a proposal, or replaces the existing one with the same id in place.
    ///
    /// Replacing in place (rather than appending a second entry) keeps a re-issued
    /// proposal at its original position, so a list the listener is reading does
    /// not reshuffle under them.
    public func add(_ proposal: AIProposal) {
        if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
            guard proposals[index] != proposal else { return }
            proposals[index] = proposal
            return
        }
        proposals.append(proposal)
    }

    public func remove(_ proposal: AIProposal) {
        remove(id: proposal.id)
    }

    /// Removes the proposal with `id`, if present. A miss writes nothing —
    /// `@Observable` notifies on same-value writes, so an unguarded reassignment
    /// would invalidate every observing view for nothing (SKILL macOS UI perf
    /// rule 3).
    public func remove(id: UUID) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals.remove(at: index)
    }

    public func contains(id: UUID) -> Bool {
        proposals.contains { $0.id == id }
    }

    public func proposal(id: UUID) -> AIProposal? {
        proposals.first { $0.id == id }
    }

    /// Drops every pending proposal. Applies nothing and undoes nothing.
    public func clear() {
        guard !proposals.isEmpty else { return }
        proposals.removeAll()
    }
}
