// ToolboxPlaylistReadObserving — the one seam that watches a read happen.
//
// ── WHY THE TOOL LAYER REPORTS THIS AT ALL ────────────────────────────────────
//
// A turn that opened a playlist and a turn that merely mentioned one look
// identical from outside: both end in prose naming a playlist. Only the tool layer
// knows which of the two happened, and only at the instant it happened — the
// rendered answer deliberately carries no playlist id (``ToolboxRendering`` emits
// track rows), so a caller downstream would have to guess by parsing text a model
// wrote. Reporting the id AT the invocation site is the one place the fact is
// exact rather than inferred.
//
// ── IT OBSERVES. IT CANNOT STEER. ─────────────────────────────────────────────
//
// The requirement does not throw and returns nothing, so an observer cannot turn a
// successful read into a refusal, reorder rows, or change what the model is told.
// That is the whole point of the shape: ``LibraryToolbox``'s answer must be
// byte-identical whether or not an observer is installed, and a requirement that
// could fail would make that a promise instead of a fact.
//
// The seam is OPTIONAL on ``LibraryToolboxContext`` for the same reason
// ``LibraryToolboxContext/playback`` is: `nil` is the shipped default, so every
// construction that predates it compiles and behaves unchanged.
//
// ── IT FIRES AFTER THE OWNERSHIP CHECK, NEVER BEFORE ──────────────────────────
//
// `get_playlist` refuses another profile's playlist with `notFound` precisely so a
// probing caller cannot use the tool to discover that one exists (see
// `LibraryToolbox+Playlists`'s header). An observer that fired before that check
// would leak the same fact out of a side door — so the call sits after
// `ownedPlaylist` has already succeeded, and a refused read reports nothing at all.
//
// ── WHY `async` ───────────────────────────────────────────────────────────────
//
// The same constraint ``ToolboxProposalFiling`` records: the conformer lives above
// `Services` in the layering and is `@MainActor`, and an actor-isolated method can
// only witness a nonisolated protocol requirement when that requirement is `async`.
//
// This file imports only Foundation; it MUST NOT import AppKit, UIKit or
// `ViewModels` (PlayerCore portability + layering invariants).
import Foundation

/// Told which playlist `get_playlist` just served, and to whom.
///
/// Observation only — see the file header for why it can neither fail nor answer.
public protocol ToolboxPlaylistReadObserving: Sendable {
    /// Reports a playlist the tool layer has just read back successfully.
    ///
    /// Called once per successful `get_playlist` call, after ownership has been
    /// confirmed and before the answer is returned. A refused read — unknown id, or
    /// an id belonging to another profile — reports nothing.
    ///
    /// - Parameters:
    ///   - id: The playlist that was served.
    ///   - profileId: The profile the read was scoped to.
    func playlistWasRead(id: Int64, profileId: Int64) async
}
