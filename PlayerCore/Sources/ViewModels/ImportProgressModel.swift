// ImportProgressModel — the observable projection of a running library import.
//
// `LibraryScanner` already streams `ScanEvent.progress` at every chunk boundary;
// until now every call site collapsed that stream with the convenience
// `scan(_:)` and showed the user nothing until the whole import finished. This
// model is the seam that turns those events into UI state: a shell renders a
// determinate progress strip from ``processed`` / ``total`` / ``fraction``, and
// the model also drives the mid-import projection refresh so a folder whose FIRST
// chunk has landed shows up in the sidebar while the rest is still importing.
//
// Two behaviours are deliberately owned here rather than duplicated in the two
// scan call sites (a user import and a watcher-triggered rescan):
//
//   * the **zero-work guard** — a pass that resolves no candidates emits no
//     `.progress` at all, so ``isImporting`` never flips and no UI appears; and
//   * the **refresh throttle** — a fast scan emits chunk events far quicker than
//     a sidebar rebuild (one `rootSummary` query per root) can absorb, so
//     ``onIncrementalRefresh`` fires at most once per ``refreshInterval``.
//
// This file imports only Foundation + Observation + Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Services

/// Live state for the import currently running, or an idle model when none is.
///
/// The model is fed by whoever owns the scan (`for await event in
/// scanner.events(for:)` ⇢ ``apply(_:)``) and read by the import-progress UI.
/// It holds no reference to the scanner, so it unit-tests against a scripted
/// event stream in complete isolation.
@MainActor
@Observable
public final class ImportProgressModel {
    /// The default minimum spacing between two mid-import projection refreshes.
    public static let defaultRefreshInterval: TimeInterval = 1

    /// Whether an import that has real work to do is currently running. Stays
    /// `false` for a pass that resolved no candidates, so the UI never flashes
    /// for a no-op rescan (the zero-work guard).
    public private(set) var isImporting = false

    /// Candidates accounted for so far in the running import.
    public private(set) var processed = 0

    /// Candidates the running import resolved in total. Always `> 0` while
    /// ``isImporting`` is `true`.
    public private(set) var total = 0

    /// The last path handled by the most recent chunk, for a "currently
    /// importing…" caption. `nil` when idle or when the scanner reported none.
    public private(set) var currentPath: String?

    /// Completion fraction in `0...1` (`0` when nothing is running).
    public var fraction: Double {
        total > 0 ? Double(processed) / Double(total) : 0
    }

    /// Refreshes the library projections mid-import so folders whose first chunk
    /// has already been committed become visible before the import finishes.
    ///
    /// Assigned once by the composition root. ``apply(_:)`` invokes it at most
    /// once per ``refreshInterval``, so a fast scan cannot flood the projections
    /// with rebuilds.
    @ObservationIgnored public var onIncrementalRefresh: (@MainActor () async -> Void)?

    @ObservationIgnored private let refreshInterval: TimeInterval
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private var lastRefreshAt: TimeInterval?

    /// - Parameters:
    ///   - refreshInterval: minimum seconds between two ``onIncrementalRefresh``
    ///     calls. `0` refreshes on every chunk (used by tests to make the call
    ///     count deterministic).
    ///   - now: monotone-enough clock reading, injectable so a test can hold time
    ///     still and assert the throttle instead of sleeping.
    public init(
        refreshInterval: TimeInterval = ImportProgressModel.defaultRefreshInterval,
        now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.refreshInterval = max(0, refreshInterval)
        self.now = now
    }

    /// Folds one scan event into the published state.
    ///
    /// A `.progress` event with no candidates is ignored entirely (the zero-work
    /// guard); a real one publishes the running tally and, when the throttle
    /// window has elapsed, awaits ``onIncrementalRefresh``. `.finished` resets the
    /// model — the closing summary is the caller's to handle, exactly as before.
    public func apply(_ event: ScanEvent) async {
        switch event {
        case let .progress(progress):
            guard progress.total > 0 else { return }
            publish(progress)
            await refreshIfDue()
        case .finished:
            reset()
        }
    }

    /// Returns the model to its idle state and re-arms the refresh throttle, so
    /// the next import's first chunk always refreshes immediately.
    public func reset() {
        if isImporting { isImporting = false }
        if processed != 0 { processed = 0 }
        if total != 0 { total = 0 }
        if currentPath != nil { currentPath = nil }
        lastRefreshAt = nil
    }
}

private extension ImportProgressModel {
    /// Publishes one chunk's tally. Every write is equality-guarded: `@Observable`
    /// notifies on same-value writes too, and this runs on a chunk cadence
    /// (SKILL macOS UI performance rule 3).
    func publish(_ progress: ScanProgress) {
        if !isImporting { isImporting = true }
        if processed != progress.processed { processed = progress.processed }
        if total != progress.total { total = progress.total }
        if currentPath != progress.currentPath { currentPath = progress.currentPath }
    }

    /// Invokes ``onIncrementalRefresh`` when at least ``refreshInterval`` seconds
    /// have passed since the last one. The stamp is taken BEFORE awaiting so a
    /// slow refresh cannot queue a second one behind itself.
    func refreshIfDue() async {
        guard let onIncrementalRefresh else { return }
        let timestamp = now()
        if let lastRefreshAt, timestamp - lastRefreshAt < refreshInterval {
            return
        }
        lastRefreshAt = timestamp
        await onIncrementalRefresh()
    }
}
