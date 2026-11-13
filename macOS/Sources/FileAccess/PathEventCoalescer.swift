// PathEventCoalescer — the pure, clock-injected debounce/coalesce engine that
// protects the library reconciler from FSEvents storms.
//
// A rename or move of a 50k-file parent folder makes FSEvents fire a burst of
// change notifications. Re-scanning per notification would hammer the database;
// instead the watcher funnels every changed path through this value type, which:
//
//   * maps each changed path to the library *root* that owns it (longest-prefix
//     match) and collapses the burst into a *set of roots* — so 50k child-path
//     events under one root coalesce into a single root to re-scan, and
//   * debounces: a flush is only "due" once the burst has been quiet for
//     `debounceInterval` (~0.5s), with a hard `maxCoalesceInterval` ceiling so a
//     never-ending storm still flushes eventually instead of starving forever.
//
// It owns NO clock, NO timer and NO FSEvents handle: every method takes the
// current time as a parameter. That makes the whole storm-protection contract
// deterministically unit-testable in isolation (see the standalone test driver
// used for `task-29-fsevents.txt`), while `FolderWatcher` feeds it
// `ProcessInfo.processInfo.systemUptime` on its private serial queue.
//
// Imports only Foundation — no AppKit, no CoreServices — so it builds and tests
// without a window server or any Apple-events machinery.
import Foundation

/// Accumulates FSEvents-style path changes into a debounced set of library roots
/// to reconcile. Pure and clock-injected; see the file header for the contract.
struct PathEventCoalescer {
    /// Quiet period that must elapse after the last event before a flush is due.
    let debounceInterval: TimeInterval
    /// Hard ceiling from the first pending event: even under a continuous storm a
    /// flush becomes due once this elapses, so reconciliation never starves.
    let maxCoalesceInterval: TimeInterval

    /// The library roots that own currently-pending changes (the re-scan set).
    private(set) var pendingRoots: Set<String> = []
    /// How many raw path events have folded into the pending set since the last
    /// drain — the storm-compression numerator (e.g. 50_000 events ⇒ 1 root).
    private(set) var coalescedEventCount = 0

    private var firstEventTime: TimeInterval?
    private var lastEventTime: TimeInterval?

    /// - Parameters:
    ///   - debounceInterval: quiet window before a flush is due (default 0.5s).
    ///   - maxCoalesceInterval: storm ceiling from the first event (default 2s).
    init(debounceInterval: TimeInterval = 0.5, maxCoalesceInterval: TimeInterval = 2.0) {
        self.debounceInterval = max(0, debounceInterval)
        self.maxCoalesceInterval = max(self.debounceInterval, maxCoalesceInterval)
    }

    /// Whether anything is waiting to be reconciled.
    var hasPendingWork: Bool {
        !pendingRoots.isEmpty
    }

    // MARK: Recording

    /// Folds a batch of changed paths into the pending set, mapping each to the
    /// library root that owns it. Paths under no known root are ignored.
    /// - Parameters:
    ///   - changedPaths: the paths FSEvents reported as changed.
    ///   - roots: the currently-watched library roots (filesystem paths).
    ///   - time: the caller's monotonic clock reading for this batch.
    mutating func record(changedPaths: [String], roots: [String], at time: TimeInterval) {
        var matched = 0
        for path in changedPaths {
            guard let owner = Self.owningRoot(of: path, among: roots) else { continue }
            pendingRoots.insert(owner)
            matched += 1
        }
        guard matched > 0 else { return }
        coalescedEventCount += matched
        if firstEventTime == nil {
            firstEventTime = time
        }
        lastEventTime = time
    }

    // MARK: Debounce decisions

    /// Whether a flush is due at `time`: either the burst has been quiet for
    /// `debounceInterval`, or the `maxCoalesceInterval` ceiling has been reached.
    func isFlushDue(at time: TimeInterval) -> Bool {
        guard !pendingRoots.isEmpty,
              let first = firstEventTime,
              let last = lastEventTime
        else {
            return false
        }
        if time - last >= debounceInterval {
            return true
        }
        return time - first >= maxCoalesceInterval
    }

    /// How long until the next flush becomes due, or `nil` when nothing is
    /// pending. Used by the watcher to arm a one-shot timer precisely instead of
    /// polling. Never negative.
    func timeUntilDue(at time: TimeInterval) -> TimeInterval? {
        guard let first = firstEventTime, let last = lastEventTime, !pendingRoots.isEmpty else {
            return nil
        }
        let dueByQuiet = last + debounceInterval
        let dueByCeiling = first + maxCoalesceInterval
        let due = min(dueByQuiet, dueByCeiling)
        return max(0, due - time)
    }

    // MARK: Draining

    /// Returns the pending roots and resets the accumulator if a flush is due at
    /// `time`, otherwise `nil` (the caller should keep waiting / re-arm).
    mutating func drainIfDue(at time: TimeInterval) -> Set<String>? {
        guard isFlushDue(at: time) else { return nil }
        return drain()
    }

    /// Unconditionally returns and clears the pending roots (e.g. on stop).
    @discardableResult
    mutating func drain() -> Set<String> {
        let roots = pendingRoots
        pendingRoots.removeAll()
        coalescedEventCount = 0
        firstEventTime = nil
        lastEventTime = nil
        return roots
    }

    // MARK: Root matching

    /// The watched root that owns `path`, by longest-prefix match on whole path
    /// components, or `nil` if none. `/a/b` owns `/a/b` and `/a/b/c` but not
    /// `/a/bc`; when roots nest, the most specific (longest) root wins.
    static func owningRoot(of path: String, among roots: [String]) -> String? {
        let target = Self.normalized(path)
        var best: String?
        for root in roots {
            let candidate = Self.normalized(root)
            guard target == candidate || target.hasPrefix(candidate + "/") else { continue }
            if best == nil || candidate.count > (best?.count ?? 0) {
                best = candidate
            }
        }
        return best
    }

    /// Strips a single trailing slash (except for the filesystem root) so prefix
    /// comparisons are boundary-correct regardless of how a root was supplied.
    private static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
