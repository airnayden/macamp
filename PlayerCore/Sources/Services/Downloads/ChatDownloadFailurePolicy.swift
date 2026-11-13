// ChatDownloadFailurePolicy — what a chat-initiated download's terminal state means for
// the playlist waiting on it. A pure function, and nothing else.
//
// ── WHY BOTH FAILURE SHAPES ATTEMPT RECOVERY ─────────────────────────────────
//
// Re-downloading a video whose file is already in the destination does NOT reliably
// report ``DownloadError/alreadyDownloaded``. That case is reached only when yt-dlp exits
// cleanly having moved no file; on the stream-copy path it instead exits with
// `ERROR: Postprocessing: Conversion failed!`, which ``YtDlpProgressParser/exitOutcome``
// maps — like every other `ExitCode.downloadError` — to ``DownloadError/downloadFailed``.
// So the shape a re-download actually produces is usually the GENERIC failure, and
// classifying only the friendly one would drop exactly the appends a person re-requesting
// a track expects to work. Both therefore go looking in the download history.
//
// The cost of being wrong in the other direction is a single indexed history read that
// finds nothing: a genuine network failure reaches ``recoverViaHistory``, resolves no
// path, and announces the same abandonment notice it would have announced anyway. That
// asymmetry — a cheap miss versus a silently lost append — is the whole argument.
//
// ── WHY TWO CANCELLATION SHAPES CLASSIFY IDENTICALLY ─────────────────────────
//
// The queue publishes a user cancellation as ``.cancelled``. The failure form
// is classified the same way. An engine-initiated stop uses its own error and
// tells the listener that the playlist append was abandoned.
//
// ── PURE, AND NAMED APART FROM THE EVENTS ────────────────────────────────────
//
// Nothing here announces, reads a repository, or touches the registry — the caller does
// all three. The ``Classification`` case names deliberately do NOT match
// ``ChatDownloadAppendEvent``'s: a classification is an instruction to the caller, an
// event is a report to the listener, and the two enums must never be mistaken for each
// other at a call site.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Classifies a download's state into what should happen to the playlist append that was
/// waiting on it.
public enum ChatDownloadFailurePolicy {
    /// What the caller should do about the registrations waiting on this download.
    public enum Classification: Equatable, Sendable {
        /// Nothing. The download is still moving, or it succeeded and the finished seam
        /// owns it from here.
        case ignore
        /// Look the video up in the download history and append from the path it
        /// recorded — no new file landed, so nothing is scanned.
        case recoverViaHistory
        /// Drop the registrations and say nothing: the person cancelled this themselves.
        case evictSilently
        /// Drop the registrations and report the abandoned append once, for the video —
        /// never once per waiting target.
        case evictWithNotice
    }

    /// The classification for `state`.
    ///
    /// The switch is EXHAUSTIVE with no `default` on purpose, in both this method and
    /// ``classify(_:)-(DownloadError)``: a new ``DownloadState`` or ``DownloadError`` case
    /// must break the build here rather than fall quietly into ``Classification/ignore``,
    /// which would be a registration that is never released and an append that never
    /// happens, with no error anywhere.
    public static func classify(_ state: DownloadState) -> Classification {
        switch state {
        case .queued, .fetchingMetadata, .downloading, .postProcessing:
            .ignore
        case .finished:
            .ignore
        case .cancelled:
            .evictSilently
        case let .failed(error):
            classify(error)
        }
    }

    /// The classification for a terminal failure.
    ///
    /// `detail` and `code` are deliberately unread: they are engine diagnostics, and a
    /// classifier that steered on them would change its answer when stderr changed.
    private static func classify(_ error: DownloadError) -> Classification {
        switch error {
        case .alreadyDownloaded, .downloadFailed:
            .recoverViaHistory
        case .cancelled:
            .evictSilently
        case .cancelledByEngine,
             .destinationUnavailable,
             .engineRestartRequired,
             .invalidArguments,
             .toolMissing,
             .unknown,
             .updateFailed:
            .evictWithNotice
        }
    }
}
