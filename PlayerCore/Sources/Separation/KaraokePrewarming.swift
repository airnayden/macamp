// KaraokeRendering — the seam over on-demand pre-separation of requested tracks.
//
// So a karaoke toggle feels instant, the render service (`KaraokeRenderService`)
// separates explicitly-requested tracks ahead of time and caches the results.
// Every call site is main-actor (the settings toggle drives `setEnabled`, a caller
// drives `requestRender`, and progress/completion are published to the UI), so the
// protocol is `@MainActor`; the heavy work is offloaded to detached tasks inside the
// conformer. Requests are plain `URL`s — Separation deliberately does NOT depend on
// Persistence/Services, so it never sees `TrackRecord`/`TrackRef`. This file imports
// only Foundation and MUST NOT import AppKit/UIKit (PlayerCore portability invariant).
import Foundation

/// A per-track render progress update, published as separation advances.
public struct KaraokePrewarmProgress: Sendable, Equatable {
    /// The original source file being rendered.
    public let url: URL
    /// Completion fraction in `0...1` for this track's separation.
    public let fraction: Double

    public init(url: URL, fraction: Double) {
        self.url = url
        self.fraction = fraction
    }
}

/// The three-way outcome of an explicit karaoke render request.
///
/// Consumers distinguish newly rendered work from cache hits and failures to
/// count real queue completions, select the correct toast, and fire render-ready
/// notifications only when new output was produced.
public enum KaraokeRenderResult: Sendable, Equatable {
    /// A new instrumental was rendered and stored in the cache.
    case rendered
    /// A valid cached instrumental satisfied the request without new rendering.
    case alreadyCached
    /// The request could not produce or resolve an instrumental.
    case failed
}

/// A snapshot of the render queue's membership and paused state, published after
/// every mutation so an observer can mirror the current item, the pending items,
/// and whether the driver is paused.
public struct KaraokeQueueSnapshot: Sendable, Equatable {
    /// The item currently being separated, or `nil` when nothing is in flight.
    public let currentURL: URL?
    /// The pending items in the driver's exact FIFO pick order.
    public let pendingURLs: [URL]
    /// Whether the driver is paused — in-flight work is cancelled and requeued.
    public let isPaused: Bool

    public init(currentURL: URL?, pendingURLs: [URL], isPaused: Bool) {
        self.currentURL = currentURL
        self.pendingURLs = pendingURLs
        self.isPaused = isPaused
    }
}

/// Drives on-demand background pre-separation of explicitly-requested tracks.
///
/// `@MainActor`-isolated because it is enabled/disabled from settings and handed
/// render requests — both on the main actor — and it publishes progress to the UI.
/// Conformers offload the actual separation to background tasks, run at most one
/// separation at a time in FIFO request order, and skip tracks that are unavailable,
/// unsupported, or already cached.
@MainActor
public protocol KaraokeRendering: AnyObject {
    /// Turns rendering on or off. Disabling cancels any in-flight separation and
    /// clears every pending request.
    func setEnabled(_ enabled: Bool)

    /// Appends an explicit render request to the FIFO. Deduplicated by URL — a
    /// request for a URL already pending or in flight is dropped. A URL whose
    /// instrumental is already cached performs no separation but still reports
    /// completion through ``onFinished`` with ``KaraokeRenderResult/alreadyCached``. A no-op while
    /// disabled.
    func requestRender(_ url: URL)

    /// Cancels any in-flight separation and clears every pending request.
    func cancelAll()

    /// Pauses the driver: any in-flight separation is cancelled, requeued at the FRONT,
    /// and not reported through ``onFinished``. No pending item starts until ``resume()``.
    func pause()

    /// Idempotently resumes the driver, clears any stop latch, and starts pending work.
    func resume()

    /// Removes a PENDING item. A no-op for the in-flight item or an absent URL.
    func removePending(_ url: URL)

    /// Moves a PENDING item to `index` (clamped to the pending range). A no-op for
    /// an absent URL.
    func movePending(_ url: URL, to index: Int)

    /// Starts rendering `url` immediately, ahead of everything else. If another
    /// item is in flight it is PREEMPTED — cancelled and requeued at the FRONT of
    /// pending, right behind `url` — so no progress is lost. A `url` already in
    /// flight is a no-op; a `url` not yet queued is enqueued. Auto-resumes a paused
    /// driver. The preempted item is not reported through ``onFinished`` (it was
    /// cancelled, not failed), and it keeps its place at the head of the queue.
    func startNow(_ url: URL)

    /// Alias for ``pause()`` retained for per-track stop controls. Any in-flight render
    /// is cancelled, requeued at the FRONT, and not reported through ``onFinished``.
    func stopCurrent()

    /// Invoked on the main actor with per-track progress as rendering advances.
    /// `@Sendable` so conformers may hop from a background task; equality-guard
    /// same-value updates before touching `@Observable` state (macOS UI-perf rule).
    var onProgress: (@Sendable (KaraokePrewarmProgress) -> Void)? { get set }

    /// Invoked on the main actor after each request finishes with its distinct rendered,
    /// already-cached, or failed outcome. Not fired for cancellation or a disk-full
    /// requeue; disk-full is surfaced only through the service's notice seam.
    var onFinished: (@Sendable (URL, KaraokeRenderResult) -> Void)? { get set }

    /// Invoked on the main actor after every queue membership/state mutation
    /// (request, start, finish, cancel, remove, move, pause, resume, disable), with
    /// a post-mutation snapshot whose `pendingURLs` are in the driver's pick order.
    var onQueueChanged: (@Sendable (KaraokeQueueSnapshot) -> Void)? { get set }
}
