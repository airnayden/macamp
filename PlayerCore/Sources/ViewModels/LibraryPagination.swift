// LibraryPagination — the pure, UI-free rules that decide when a keyset-paginated
// track list fetches its next page, plus the one-in-flight latch that keeps a
// burst of row-appearance events from issuing one fetch per visible row.
//
// Extracted from the macOS `LibraryBrowserView` so the proximity rule is directly
// unit-testable without SwiftUI: the shell owns *where* the trigger fires, this
// file owns *whether* it should fire. Foundation only — no view framework, no
// repository (PlayerCore portability invariant).
import Foundation

/// Threshold-prefetch policy for keyset-paginated track lists.
///
/// Lists used to fetch the next page only when the very last loaded row appeared,
/// which left a visible stall at the bottom of every page. Fetching once the
/// appearing row is within ``prefetchThreshold`` of the end hides the fetch behind
/// rows the reader has not scrolled past yet. Page size is unchanged — this moves
/// *when* a page is requested, never how large it is.
public enum LibraryPagination {
    /// Distance from the end of the loaded window at which the next page is fetched.
    public static let prefetchThreshold = 25

    /// Row count a freshly loaded window tops up to, so a tall window starts filled.
    public static let viewportFillTarget = 150

    /// Hard cap on how many pages one viewport fill may request.
    public static let viewportFillMaxPages = 3

    /// Whether the row at `index` of a `count`-row window should trigger a page fetch.
    ///
    /// Every row of a window shorter than `threshold` qualifies — a short window is
    /// entirely "near the end". An index outside the window never qualifies: a row
    /// whose identity has left the loaded set must not drive a fetch.
    ///
    /// - Parameters:
    ///   - index: Position of the appearing row within the loaded window.
    ///   - count: Number of rows currently loaded.
    ///   - threshold: Distance from the end that counts as near. Values below `1`
    ///     are clamped to `1` so the last row always triggers.
    /// - Returns: `true` when the next page should be requested.
    public static func shouldPrefetch(
        index: Int,
        count: Int,
        threshold: Int = prefetchThreshold
    ) -> Bool {
        guard index >= 0, index < count else { return false }
        return count - index <= max(1, threshold)
    }
}

/// A one-fetch-in-flight latch for paginated list loading.
///
/// Scrolling past the prefetch threshold makes every row in the trailing window
/// appear at once; each appearance asks to load. ``begin()`` succeeds for the
/// first and fails for the rest, so the burst issues exactly one page fetch.
///
/// The view models' own `isLoading` guards stay the backstop against *concurrent*
/// loads; this gate additionally suppresses the *sequential* over-fetch a queue of
/// already-scheduled triggers would otherwise cause once the first load resolves.
///
/// Deliberately a plain class, not `@Observable`: the latch flips on a scroll
/// cadence and must never invalidate a view body.
@MainActor
public final class LibraryPrefetchGate {
    /// `true` while a fetch claimed through ``begin()`` is still running.
    public private(set) var isFetching = false

    /// Creates an open gate.
    public init() {}

    /// Claims the gate for one fetch.
    ///
    /// - Returns: `true` when the caller now owns the gate and must call ``end()``
    ///   when its fetch finishes; `false` when a fetch is already in flight.
    public func begin() -> Bool {
        guard !isFetching else { return false }
        isFetching = true
        return true
    }

    /// Releases the gate. Safe to call on an already-open gate.
    public func end() {
        isFetching = false
    }
}
