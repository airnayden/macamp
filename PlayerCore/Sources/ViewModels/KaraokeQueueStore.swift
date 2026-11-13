// KaraokeQueueStore — the in-memory projection of the karaoke render queue that
// drives the Karaoke Queue sidebar section: which source file is being separated
// right now, which are waiting (FIFO), whether the driver is paused, and how far
// the in-flight render has progressed.
//
// This is presentation state ONLY. Like ``KaraokeReadyStore``, it is NEVER persisted
// (GRDB / snapshot / UserDefaults): the render queue is a runtime concept owned by
// `KaraokeRenderService`, and this store is a transient projection of that service's
// `onQueueChanged` / `onProgress` seams, rebuilt from scratch every launch. It is
// wire-agnostic — the composition root connects the render service's seams into it
// (nothing here reaches back), so it can be unit-tested in complete isolation.
//
// This file imports only Foundation + Observation + Separation; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Separation

/// Tracks the live karaoke render queue — the in-flight item, the pending items in
/// queue order, the paused flag, and the current render's progress — for the Karaoke
/// Queue UI.
///
/// All state is in-memory and rebuilt from the render service's queue/progress seams;
/// nothing here is persisted. Snapshot URLs are canonicalized exactly like
/// `SeparationCacheKey` / ``KaraokeReadyStore``, so the paths match the ready set and
/// the repository's `filePath`s.
@MainActor
@Observable
public final class KaraokeQueueStore {
    /// The canonical source path of the render in flight, or `nil` when idle.
    public private(set) var currentPath: String?

    /// The canonical source paths waiting to render, in queue (FIFO) order.
    public private(set) var pendingPaths: [String] = []

    /// Whether the render driver is paused — the in-flight item still finishes, but
    /// no new item starts until resumed.
    public private(set) var isPaused = false

    /// The in-flight render's progress (`0...1`), for the current item's progress bar.
    /// Reset to `0` whenever the current item changes.
    public private(set) var currentProgress: Double = 0

    /// A generation counter bumped ONLY on a membership change (current / pending /
    /// paused) — never on a progress tick. A consumer that lays out the queue observes
    /// this to cheaply decide "re-resolve the rows"; a progress-bar consumer observes
    /// ``currentProgress`` directly, so it never churns the queue layout. Same design
    /// as ``KaraokeReadyStore/version``.
    public private(set) var version = 0

    /// Creates an empty store. The composition root connects it to the render
    /// service's queue/progress seams in a later step.
    public init() {}

    /// Whether `filePath` is in the render queue — the in-flight item or any pending
    /// item. Canonicalizes the input exactly like ``KaraokeReadyStore``, so a lookup
    /// matches the stored paths regardless of how the caller spelled the path.
    public func isQueued(filePath: String) -> Bool {
        let path = Self.canonicalPath(filePath)
        return path == currentPath || pendingPaths.contains(path)
    }

    /// Whether the render driver is actively working — an item is in flight and the
    /// driver is not paused. A paused or idle queue is not working, so a state-aware
    /// control shows "start"; a working one shows "pause".
    public var isWorking: Bool {
        currentPath != nil && !isPaused
    }

    /// Applies a render-queue snapshot, replacing the current / pending / paused state.
    ///
    /// - Equality guard: a snapshot that maps to the same membership neither bumps
    ///   ``version`` nor reassigns the observable state (avoids needless re-renders,
    ///   SKILL macOS UI perf rule 3).
    /// - Progress reset: when the in-flight item changes, ``currentProgress`` resets
    ///   to `0` so the new item's bar starts empty. Progress never affects ``version``.
    public func ingest(snapshot: KaraokeQueueSnapshot) {
        let newCurrent = snapshot.currentURL.map(Self.canonicalPath)
        let newPending = snapshot.pendingURLs.map(Self.canonicalPath)
        let newPaused = snapshot.isPaused

        guard newCurrent != currentPath
            || newPending != pendingPaths
            || newPaused != isPaused
        else { return }

        if newCurrent != currentPath, currentProgress != 0 {
            currentProgress = 0
        }
        currentPath = newCurrent
        pendingPaths = newPending
        isPaused = newPaused
        version += 1
    }

    /// Records render progress for `url`, but only while it is the in-flight item.
    /// Progress only ever increases (a lower or equal fraction is ignored) so an
    /// out-of-order tick can't rewind the bar; `fraction` is clamped to `0...1`. Does
    /// NOT bump ``version`` — observe ``currentProgress`` directly.
    public func ingestProgress(url: URL, fraction: Double) {
        guard let currentPath, Self.canonicalPath(url) == currentPath else { return }
        let clamped = min(max(fraction, 0), 1)
        guard clamped > currentProgress else { return }
        currentProgress = clamped
    }
}

private extension KaraokeQueueStore {
    /// Canonicalizes a file URL exactly like `SeparationCacheKey.sourceIdentity(for:)`
    /// and ``KaraokeReadyStore``, so queue paths match the ready set and repository rows.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Canonicalizes a file-system path string the same way, for ``isQueued(filePath:)``.
    nonisolated static func canonicalPath(_ path: String) -> String {
        canonicalPath(URL(fileURLWithPath: path))
    }
}
