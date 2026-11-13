// LibraryChatPlaylistContextRecorder — the production witness for W1's read seam.
//
// `get_playlist` is the ONE tool that establishes which playlist a turn is about
// without filing anything, and ``ToolboxPlaylistReadObserving`` is the only channel
// that says so: the rendered answer carries track rows and no playlist id, so a
// surface downstream would have to guess by parsing prose a model wrote.
//
// ── WHY `@MainActor` CAN WITNESS A `Sendable` PROTOCOL ────────────────────────
//
// Verbatim the arrangement ``LibraryChatProposalFiler`` records: `playlistWasRead`
// is `async` in the protocol precisely so an actor-isolated method may witness it,
// and the toolbox reaches this from whatever executor the tool ran on with an
// `await`. `@MainActor` because the chat view model that drains it is.
//
// ── THE DRAIN IS HOW A TURN LEARNS WHAT IT READ ───────────────────────────────
//
// Same contract as the filer's, for the same reason: `drain()` hands the reads to
// the chat view model at the end of a turn, in call order, and clears them — so a
// playlist is attributed to exactly one message and never to the next one.
//
// It only RECORDS. The seam cannot fail, cannot reorder rows, and cannot change what
// the model is told, so installing this leaves `get_playlist`'s answer byte-identical.
import Foundation
import Services

/// Records which playlists `get_playlist` served, until a turn claims them.
@MainActor
final class LibraryChatPlaylistContextRecorder: ToolboxPlaylistReadObserving {
    private var reads: [(playlistId: Int64, profileId: Int64)] = []

    func playlistWasRead(id: Int64, profileId: Int64) async {
        reads.append((playlistId: id, profileId: profileId))
    }

    /// The reads since the previous call, oldest first.
    func drain() -> [(playlistId: Int64, profileId: Int64)] {
        defer { reads.removeAll() }
        return reads
    }
}
