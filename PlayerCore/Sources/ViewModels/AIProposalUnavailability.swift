// AIProposalUnavailability — why a contextual action produced nothing, when that
// is a normal outcome rather than a failure.
//
// ``AssistantProposalError`` answers "the request FAILED"; this answers "the
// request was fine and there is simply nothing to review". Both can be `nil` at
// once (a proposal was filed), and neither is derivable from the other, which is
// the same orthogonality ``AssistantTierDiagnostic`` already has against
// ``AssistantProposalError``.
//
// It exists because the contextual proposers in `AssistantViewModel+Contextual.swift`
// return `nil` for FIVE structurally different reasons and the shell collapsed all
// of them into one "nothing to propose" toast — so "this playlist is longer than
// the generator can rank", "not enough of this playlist has been analysed yet" and
// "it is already in energy order" were indistinguishable to the listener, and only
// one of the three is something they can act on.
//
// EVERY contextual proposer sets it, not just the energy reorder: a reason channel
// that only one caller filled would be an ad-hoc side channel, and the next caller
// to need one would add a second.
//
// PlayerCore portability: Foundation only.
import Foundation

/// Why a contextual proposer filed no proposal, for the cases that are not errors.
public enum AIProposalUnavailability: Sendable, Equatable, Hashable {
    /// A request was already in flight, so this one was dropped rather than queued.
    case busy

    /// The selection holds fewer tracks than the action needs.
    case selectionTooShort(minimum: Int)

    /// The selection holds more tracks than the generator ranks, so an arc over it
    /// would describe a prefix while claiming the whole list.
    case selectionTooLong(limit: Int)

    /// Too little of THIS selection carries analysed energy for the arc to mean
    /// anything — ``MixRanking/energyArcCoverage`` measured after the mix pipeline
    /// dropped whatever it could not resolve.
    ///
    /// Distinct from the library-wide coverage gate the menu applies: a fully
    /// analysed library can still contain a playlist of unanalysed tracks.
    case insufficientAnalysis(required: Double)

    /// The action ran and changed nothing — already in order, nothing listed
    /// twice, or the suggested name is the name it already has.
    case nothingToChange

    /// The view model was composed without the backend this action needs.
    case backendUnavailable
}
