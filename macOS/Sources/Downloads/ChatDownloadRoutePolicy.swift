// ChatDownloadRoutePolicy — which of the two import paths a finished download takes.
//
// A finished download can reach the library two ways, and it must take exactly ONE of
// them:
//
//   * the LEGACY path — `DownloadLibraryImporter` behind the auto-import switch, which
//     is what every download that nobody is waiting on has always done; or
//   * the APPENDER path — `ChatDownloadPlaylistAppender`, which runs its own gate and
//     its own single scan and then appends the resulting row to the playlist(s) the
//     chat turn registered.
//
// Both would import, so letting both run means two scans of the same file and two
// "added to your library" toasts for one download. The appender is the strictly
// stronger path (it does everything the legacy one does and then some), so a claimed
// registration suppresses the legacy path outright.
//
// ── WHY THE INPUT IS A BOOL AND NOT THE REGISTRY ─────────────────────────────
//
// The caller CLAIMS — destructively, synchronously, inside the seam's own
// `MainActor.assumeIsolated` — and hands the answer here. If this type held the
// registry it would have to claim for itself, and the only place that could happen is
// after the caller had already decided whether to suppress, which is the split
// `ChatDownloadPlaylistAppender`'s header names as the silent-no-import bug. Taking a
// `Bool` makes that impossible to get wrong: there is nothing here to claim with.
//
// Pure and total, so it costs one table-driven test rather than a queue, a database
// and a temporary directory — `DownloadRecoveryPolicy` / `DownloadImportAnnouncement`
// (`DownloadFinishPolicies.swift`) are the same shape for the same reason.
import Foundation

/// Which import path a finished chat-initiated download should take.
enum ChatDownloadRoutePolicy {
    /// The path a finished download takes.
    enum Route: Equatable {
        /// Hand the file to ``ChatDownloadPlaylistAppender`` and SKIP the legacy
        /// importer and its toast — the appender runs the gate and the one scan.
        case appender
        /// Today's path, byte for byte: `DownloadLibraryImporter` plus the
        /// "added to your library" toast when it actually imported something.
        case legacyImport
    }

    /// - Parameter isRegistered: whether the claim the caller already made came back
    ///   non-empty. `false` covers both "never registered" and "registered, but the
    ///   registration was evicted before the file landed" — from here they are the same
    ///   fact and must take the same path.
    static func route(isRegistered: Bool) -> Route {
        isRegistered ? .appender : .legacyImport
    }
}
