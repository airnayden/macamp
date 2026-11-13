// ChatDownloadAppendEvent — the one vocabulary for "what became of a chat-initiated
// download on its way to a playlist".
//
// SINGLE DECLARATION SITE, deliberately. Three separate pieces of work emit and consume
// these: the finish-side pipeline (`ChatDownloadPlaylistAppender`, todo 4) announces
// most of them, the failure-policy route (todo 5) picks between
// ``alreadyDownloadedUnresolved`` and ``appendAbandoned`` for a download that never
// produced a file, and the shell-side coalescer (todo 9) switches over the WHOLE enum
// exhaustively to decide what the listener is told. That last consumer is why the case
// list lives in its own file rather than nested inside the appender: an exhaustive
// `switch` is only a safety net if adding a case here breaks the coalescer's build, and
// the cases must be declarable before the type that will eventually announce them all.
//
// The enum is intentionally a REPORT, not a command. Nothing downstream re-drives the
// pipeline from an event; the appender has already finished acting by the time it
// announces. That is what lets the shell coalesce, drop, or rate-limit events freely.
//
// This file imports only Foundation (for `UUID`) and MUST NOT import AppKit/UIKit,
// Process, or URLSession — PlayerCore portability invariant plus the downloader
// boundary gate.
import Foundation

/// What happened to one chat-initiated download's journey into a playlist.
public enum ChatDownloadAppendEvent: Equatable, Sendable {
    /// The track is now a member of the playlist. The terminal success.
    case appended(playlistId: Int64, trackId: Int64)
    /// The download finished before its proposal was applied, so the track id is parked
    /// on the registry until that proposal acquires a real playlist id.
    case heldForProposal(UUID)
    /// The import gate refused this file, so NO scan was run. Announced once per
    /// finished item, never once per waiting target.
    case gateFailed
    /// A scan ran but the file never resolved to a library row. Announced once per
    /// finished item.
    case importFailed
    /// The playlist this track was bound for no longer exists.
    case playlistMissing(Int64)
    /// The track was already a member, so the append was skipped rather than doubled.
    case alreadyInPlaylist(playlistId: Int64, trackId: Int64)
    /// The membership write itself failed. Distinct from ``playlistMissing(_:)``: the
    /// playlist was there and the write still did not land.
    case appendFailed(Int64)
    /// The active profile is no longer the one that asked for this download, so its
    /// append was abandoned rather than re-attributed.
    case skippedProfileChanged
    /// The engine reported the video as already downloaded and the recorded file could
    /// not be resolved to a library row, so there is nothing to append.
    case alreadyDownloadedUnresolved
    /// The generic "this download will not reach the playlist" eviction notice, for
    /// every give-up reason that is not one of the specific cases above.
    case appendAbandoned
    /// The registry is at its cap, so the link between this download and its playlist
    /// could not be recorded at all. Carries the current registration count.
    case queueFull(count: Int)
    /// Registration time: the proposal this download was aimed at is gone and never
    /// resolved to a playlist, so there is nothing left to register against.
    case notRegisteredNoPlaylist
}
