// DownloadQueueing — the seam over the serial YouTube download queue.
//
// Shaped after `KaraokeRendering`: `@MainActor` because every call site is the UI
// (paste, confirm, pause, reorder) and both seams publish to the UI; the conformer
// offloads the actual transfers to detached tasks and picks rows up in FIFO order, a
// bounded number at a time. The queue is IN-MEMORY ONLY — nothing here is persisted
// (karaoke precedent), so a relaunch starts empty by design.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate). The
// production conformer reaches the outside world exclusively through
// ``ToolProcessRunning`` and ``DownloadToolProviding``.
import Foundation

/// Drives the cancellable, FIFO queue of YouTube audio downloads.
///
/// `@MainActor`-isolated for the same reason `KaraokeRendering` is: it is driven from
/// UI actions and publishes progress back to the UI. Conformers pick rows up in FIFO
/// order, run at most ``DownloadQueueLimits/maxConcurrentDownloads`` of them at once,
/// and dedupe on ``DownloadItem/canonicalVideoID``.
@MainActor
public protocol DownloadQueueing: AnyObject {
    /// Accepts `urls`, appending one row per newly-seen canonical video id.
    ///
    /// Single-video URLs are appended immediately. A URL that ``YouTubeURLNormalizer``
    /// classifies as a playlist is expanded and HELD — nothing is queued for it until
    /// ``confirmPlaylist(_:)`` is called with the returned token. URLs that name
    /// neither a video nor a playlist are ignored. Enqueues that would push the queue
    /// past ``DownloadQueueLimits/maxQueueDepth`` are dropped rather than accepted and
    /// starved.
    ///
    /// - Returns: The accepted count, the deduplicated count, and any playlist
    ///   awaiting confirmation — all three at once, because one paste routinely mixes
    ///   singles with a playlist.
    func enqueue(urls: [URL]) async -> EnqueueOutcome

    /// Commits the playlist expansion previously held under `pendingToken`.
    ///
    /// - Returns: The outcome of appending the held entries. A stale or already-
    ///   discarded token returns ``EnqueueOutcome/zero`` — the UI reports "0 added"
    ///   rather than treating an expired confirmation as an error.
    func confirmPlaylist(_ pendingToken: UUID) async -> EnqueueOutcome

    /// Cancels every in-flight download and lets the queue advance to its pending rows.
    /// A no-op when nothing is in flight.
    func cancelCurrent()

    /// Cancels ONE in-flight row by ``DownloadItem/id``, leaving its siblings running.
    /// A no-op for a row that is not in flight.
    func cancel(itemID: UUID)

    /// Removes a PENDING row. A no-op for an in-flight row or an unknown id.
    func removePending(_ id: UUID)

    /// Moves a PENDING row to `index` (clamped to the pending range). A no-op for an
    /// unknown id.
    func movePending(_ id: UUID, to index: Int)

    /// Stops the queue picking up anything NEW. Rows already in flight run to
    /// completion — nothing is cancelled and nothing is requeued — and no pending row
    /// starts until ``resume()``.
    func pause()

    /// Idempotently resumes the driver and starts pending work.
    func resume()

    /// Cancels every in-flight download and clears every pending row.
    func cancelAll()

    /// Invoked on the main actor after every queue membership/state mutation
    /// (enqueue, confirm, start, finish, cancel, remove, move, pause, resume), with a
    /// post-mutation snapshot whose `pendingItems` are in the driver's pick order.
    /// `@Sendable` so conformers may hop from a background task.
    var onQueueChanged: (@Sendable (DownloadQueueSnapshot) -> Void)? { get set }

    /// Invoked on the main actor as an individual row advances, identified by
    /// ``DownloadItem/id``. Fires far more often than ``onQueueChanged`` (once per
    /// engine progress sample), so observers must equality-guard before touching
    /// `@Observable` state — same-value writes still invalidate views (macOS UI-perf rule).
    var onItemProgress: (@Sendable (UUID, DownloadState) -> Void)? { get set }
}
