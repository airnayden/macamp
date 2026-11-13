// AIProposal+Excluding — narrowing a proposal to the tracks the listener kept ticked.
//
// The preview sheet lists every track a proposal would touch with a checkbox beside
// it. Unticking one must not mean "apply anyway and hope"; it must produce a
// DIFFERENT, smaller proposal, and that proposal is what the single write path
// receives. This file is that narrowing, and it is pure: no repository, no I/O, no
// mutation of the receiver.
//
// ── THE ID IS PRESERVED, DELIBERATELY ──────────────────────────────────────────
//
// `AssistantViewModel.apply` refuses a proposal that is not in ``ProposalStore``, by
// id. A filtered copy therefore keeps the ORIGINAL id: it is the same offer, narrowed
// by the listener, not a new one. Minting a fresh id here would make every partial
// apply throw `unknownProposal`.
//
// ── WHAT "EXCLUDED" MEANS, PER KIND ────────────────────────────────────────────
//
//   createPlaylist   the track is not put in the new playlist.
//   organize         the track keeps the membership AND position it has today —
//                    see ``PlaylistOrganizeDiff/excluding(trackIds:)``, which is the
//                    only case where "leave it alone" is more than a filter.
//   rename           unaffected: a rename touches no track, so the sheet shows no
//                    checkboxes and this returns the receiver untouched.
//   tagChangeSet     the track's file is not written.
//
// Ids the preview never listed (the list is capped — see
// `ProposalPreviewModel.maxResolvedIds`) can never enter the excluded set, so they
// stay included by construction. That is the intended truncation rule, not an
// oversight: applying uses the whole list, and the sheet says so.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit (PlayerCore
// portability invariant).
import Foundation

public extension AIProposal {
    /// A copy of this proposal with `excluded` removed from everything it would do.
    ///
    /// Returns the receiver unchanged when `excluded` is empty, so the default
    /// "everything ticked" state costs nothing and is byte-identical to the original.
    func excluding(trackIds excluded: Set<Int64>) -> AIProposal {
        guard !excluded.isEmpty else { return self }
        return AIProposal(id: id, profileId: profileId, kind: kind.excluding(trackIds: excluded))
    }
}

public extension AIProposal.Kind {
    /// Exhaustive with no `default:` — a fifth kind must decide what exclusion means
    /// for it before the build succeeds.
    func excluding(trackIds excluded: Set<Int64>) -> AIProposal.Kind {
        switch self {
        case let .createPlaylist(request):
            .createPlaylist(request.excluding(trackIds: excluded))
        case let .organize(playlistId, diff):
            .organize(playlistId: playlistId, diff: diff.excluding(trackIds: excluded))
        case .rename:
            self
        case let .tagChangeSet(patches):
            .tagChangeSet(patches: patches.filter { !excluded.contains($0.trackId) })
        }
    }
}

public extension CreatePlaylistRequest {
    /// The same request over a shorter draft.
    ///
    /// ``PlaylistDraft/nameHint``'s `trackCount` follows the entries, because its
    /// documented meaning is how many tracks the draft actually holds. The draft's
    /// three outcome flags and `totalDuration` are left alone on purpose: they are
    /// facts about the ORDER THE GENERATOR PRODUCED, and dropping rows from it does
    /// not retroactively change what the pipeline was able to do.
    func excluding(trackIds excluded: Set<Int64>) -> CreatePlaylistRequest {
        var narrowed = self
        narrowed.draft.entries = draft.entries.filter { !excluded.contains($0.trackId) }
        narrowed.draft.nameHint.trackCount = narrowed.draft.entries.count
        return narrowed
    }
}

public extension PlaylistOrganizeDiff {
    /// A diff in which every excluded track keeps exactly the membership and
    /// position it has right now.
    ///
    /// ``proposedTrackIds`` is the COMPLETE membership `reorder` writes, so a track
    /// merely dropped from it is deleted from the playlist — which is the opposite of
    /// "leave it alone" for a track the proposal wanted to REMOVE. The narrowing is
    /// therefore a pin-and-reflow rather than a filter:
    ///
    ///   1. every excluded id is removed from the proposed order, wherever it sat;
    ///   2. every excluded id that is in the CURRENT membership is re-inserted at its
    ///      current index (clamped to the shortened list).
    ///
    /// Which lands each of the three change classes exactly where the listener meant:
    ///
    ///   excluded addition   in proposed, not in current  -> dropped: never added.
    ///   excluded removal    in current, not in proposed  -> restored at its old spot.
    ///   excluded move       in both                      -> pinned back to its old spot.
    ///
    /// Insertion walks `currentTrackIds` in ascending index order, so several pins in
    /// one narrowing land in their original relative order rather than fighting for a
    /// slot. The result is re-derived through ``init(currentTrackIds:proposedTrackIds:)``
    /// so the three difference lists can never disagree with the membership.
    func excluding(trackIds excluded: Set<Int64>) -> PlaylistOrganizeDiff {
        guard !excluded.isEmpty else { return self }
        var reflowed = proposedTrackIds.filter { !excluded.contains($0) }
        for (index, trackId) in currentTrackIds.enumerated() where excluded.contains(trackId) {
            reflowed.insert(trackId, at: min(index, reflowed.count))
        }
        return PlaylistOrganizeDiff(currentTrackIds: currentTrackIds, proposedTrackIds: reflowed)
    }
}
