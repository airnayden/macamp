// LibraryChatViewModel+AppendTarget — which playlist a turn was ABOUT, resolved from
// what its tools actually did.
//
// Split out of ``LibraryChatViewModel`` so that file holds the turn loop alone — the
// same arrangement `+Enrichment.swift` records, and the members this reaches for are
// internal rather than `private` for exactly that reason.
//
// ── THE TARGET IS TURN-SCOPED, NOT MESSAGE-SCOPED ────────────────────────────
//
// Two recorders watch one turn: the proposal filer (``ToolboxProposalFiling``) and the
// playlist-read observer (``ToolboxPlaylistReadObserving``). Between them they answer
// "which playlist is this conversation about right now", and the answer belongs to the
// TURN — which is why the corrective follow-up can settle it for the row ABOVE it.
//
// ── THE PRECEDENCE, AND WHY IT IS THAT WAY ROUND ─────────────────────────────
//
//   1. A proposal filed this turn WINS. An offer the listener is looking at is what
//      they are about to act on; a playlist the model merely opened on the way there
//      is context. `appendProfileId` stays `nil` — the proposal carries its own
//      `profileId` and the shell reads it from the proposal store at registration
//      time rather than having this layer restate it.
//   2. Otherwise the LAST playlist read this turn. A model that opened three to
//      compare them meant the one it settled on, and its `profileId` is authoritative
//      because it is the profile the tool actually ran as.
//   3. Otherwise nothing. A plain download stays a plain download.
//
// ── EVERY FILED ID IS A CREATE-PLAYLIST PROPOSAL ─────────────────────────────
//
// ``ToolboxProposalFiling`` has exactly ONE requirement — `fileCreatePlaylistProposal`
// — so the drain cannot carry any other kind and "the first createPlaylist proposal"
// is simply the first drained id. No second closure is needed to tell them apart, and
// adding one would be a seam with nothing on the other side of it.
//
// This file imports only Foundation and Services; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Services

/// The append target one turn's two drains name, resolved by the one precedence rule.
///
/// A value type so the rule is a function over plain data a test can drive directly,
/// rather than a branch buried inside the turn loop — and so BOTH landings resolve it
/// by construction instead of by two copies of the same `if`.
struct ChatAppendTargetCapture: Equatable {
    /// Where a download from this turn's suggestions should be appended, or `nil`.
    let target: SuggestionAppendTarget?
    /// The profile a ``SuggestionAppendTarget/playlist(_:)`` target was read as.
    let profileId: Int64?

    init(proposals: [UUID], reads: [(playlistId: Int64, profileId: Int64)]) {
        if let proposal = proposals.first {
            target = .pendingProposal(proposal)
            profileId = nil
        } else if let read = reads.last {
            target = .playlist(read.playlistId)
            profileId = read.profileId
        } else {
            target = nil
            profileId = nil
        }
    }

    /// The proposal this capture names, or `nil` when it names a playlist or nothing.
    ///
    /// What the corrective back-fill keys on, so "did this turn file an offer" is
    /// asked in exactly one place.
    var proposalId: UUID? {
        target?.proposalId
    }
}

extension LibraryChatViewModel {
    /// Settles `identifier`'s row on the proposal the CORRECTIVE turn filed.
    ///
    /// Load-bearing, and the common path rather than an edge: ``correct(through:generation:backFilling:)``
    /// is entered precisely when the first landing filed NOTHING, and the directive
    /// tells the model to file rather than answer — so the `match_tracks` suggestions
    /// sit on the row above while the proposal lands on the row below. Without this,
    /// per-message precedence would leave the suggestion row with no target and the
    /// whole feature would silently degrade to download-only in exactly that flow.
    ///
    /// Only the PROPOSAL case back-fills. A corrective turn that merely read a playlist
    /// settles its own row and leaves the one above alone: a read is context the row
    /// above never saw, while a filed offer is the answer it was asking for.
    ///
    /// The row is re-read from ``messages`` HERE rather than captured earlier, so an
    /// enrichment that rewrote it in between is preserved — and, because that rebuild
    /// likewise copies the live row, so is this write when the order is the other way
    /// round. `replaceMessage(id:with:)` is the one writer either path has.
    func backFillAppendTarget(
        _ capture: ChatAppendTargetCapture,
        ontoRowWith identifier: UUID,
        generation turnGeneration: Int
    ) {
        guard turnGeneration == generation,
              let proposal = capture.proposalId,
              let row = messages.first(where: { $0.id == identifier })
        else { return }
        replaceMessage(id: identifier, with: row.withAppendTarget(.pendingProposal(proposal)))
    }
}
