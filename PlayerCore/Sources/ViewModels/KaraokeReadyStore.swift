// KaraokeReadyStore — the in-memory index of which library tracks a warm
// instrumental cache can play instantly, plus the per-track render progress that
// drives the karaoke row rings.
//
// This is presentation state ONLY. It is NEVER persisted to GRDB, a snapshot, or
// UserDefaults: the authoritative source paths live solely in the cache's own
// `index.json` sidecar. This store is a transient projection of the cache
// change-seam (`InstrumentalCaching.readySnapshot()` / `setOnEntriesChanged`),
// rebuilt from scratch on every launch. It is wire-agnostic — the composition root
// connects the cache seam and render service into it (nothing here reaches back to
// either), so it can be unit-tested in complete isolation.
//
// The seam fires `(sequence, records)` where `sequence` is a monotonic counter the
// cache actor bumps once per membership mutation. The composition root validates
// each record's on-disk freshness OFF the main actor and then hops back here, so two
// applications can race; `ingest` drops any whose `sequence` is not strictly newer
// than the last applied one (the reorder guard) so a stale tail never overwrites a
// fresher head.
//
// Path canonicalization is delegated to `Separation.CanonicalSourcePath`, the single
// normalizer the instrumental cache also matches removals against.
//
// This file imports only Foundation + Observation + Separation; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Separation

/// Tracks which source files have a ready cached instrumental, and how far any
/// in-flight render has progressed, for the karaoke UI.
///
/// All state is in-memory and rebuilt from the cache change-seam — nothing here is
/// persisted (the cache's `index.json` sidecar is the only on-disk record of
/// instrumentals). Reads (``isReady(filePath:)`` / ``progress(filePath:)``)
/// canonicalize their input exactly like `SeparationCacheKey`, so a lookup matches
/// the stored paths regardless of how the caller spelled the path.
@MainActor
@Observable
public final class KaraokeReadyStore {
    /// Canonical source paths whose instrumental the cache can serve instantly.
    public private(set) var readyPaths: Set<String> = []

    /// In-flight render progress per canonical source path (`0...1`), for row rings.
    public private(set) var renderProgress: [String: Double] = [:]

    /// A generation counter bumped ONLY when ``readyPaths`` changes — a one-`Int`
    /// signal a consumer can observe to cheaply decide "re-read the ready list" without
    /// diffing the whole set. Progress ticks do NOT bump it (observe ``renderProgress``
    /// directly for those) so a ready-list consumer never churns on progress.
    public private(set) var version = 0

    /// The highest change-seam `sequence` applied so far; any application whose
    /// sequence is not strictly newer is dropped (the reorder guard). Pure bookkeeping,
    /// never observed. Starts at `-1` (not `0`) so the FIRST application — the launch
    /// `readySnapshot()` returns `sequence: 0` until the cache's first mutation — is not
    /// dropped by `0 > 0`; the cache counter only ever emits `0` and up.
    @ObservationIgnored private var lastAppliedSequence = -1

    /// Creates an empty store. The composition root connects it to the cache
    /// change-seam and render service in a later step.
    public init() {}

    /// Whether `filePath` has a ready cached instrumental. Canonicalizes the input
    /// the same way `SeparationCacheKey` does, so it matches the stored paths.
    public func isReady(filePath: String) -> Bool {
        readyPaths.contains(Self.canonicalPath(filePath))
    }

    /// The in-flight render progress (`0...1`) for `filePath`, or `nil` when no render
    /// is active for it.
    public func progress(filePath: String) -> Double? {
        renderProgress[Self.canonicalPath(filePath)]
    }

    /// Applies a cache change-seam snapshot, replacing the ready set.
    ///
    /// - Reorder guard: an application whose `sequence` is not strictly newer than the
    ///   last applied one is dropped in full, so the async freshness-stat + main-hop
    ///   tail can never let a stale snapshot overwrite a fresher one.
    /// - Staleness: `isFresh` decides whether a record's cached instrumental is still
    ///   valid for the current on-disk source. Production passes a signal the
    ///   composition root computed OFF the main actor; the default (``isFreshOnDisk(_:)``)
    ///   re-stats each record's source and compares `(size, mtime)` — the same
    ///   fingerprint `SeparationCacheKey` hashes — so the exclusion is testable in
    ///   isolation. A record that fails the check is left out of the ready set.
    /// - Equality guard: an application that yields the same ready set neither bumps
    ///   ``version`` nor reassigns ``readyPaths`` (avoids needless re-renders).
    public func ingest(
        sequence: Int,
        records: [ReadyRecord],
        isFresh: (ReadyRecord) -> Bool = KaraokeReadyStore.isFreshOnDisk
    ) {
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence

        var fresh = Set<String>()
        fresh.reserveCapacity(records.count)
        for record in records where isFresh(record) {
            fresh.insert(Self.canonicalPath(record.sourcePath))
        }

        guard fresh != readyPaths else { return }
        readyPaths = fresh
        version += 1
    }

    /// Records render progress for `url`. Progress only ever increases per path (a
    /// lower or equal fraction is ignored) so an out-of-order tick can't rewind a ring;
    /// `fraction` is clamped to `0...1`.
    public func ingestProgress(url: URL, fraction: Double) {
        let path = Self.canonicalPath(url)
        let clamped = min(max(fraction, 0), 1)
        guard clamped > (renderProgress[path] ?? 0) else { return }
        renderProgress[path] = clamped
    }

    /// Clears the in-flight progress ring for `url` when its render ends. Readiness is
    /// driven solely by the cache change-seam via ``ingest(sequence:records:isFresh:)``,
    /// so the ring clears whether the render succeeded or failed; the shell temporarily
    /// maps ``KaraokeRenderResult`` onto this narrow Boolean API.
    public func finishRender(url: URL, success _: Bool) {
        let path = Self.canonicalPath(url)
        guard renderProgress[path] != nil else { return }
        renderProgress[path] = nil
    }
}

public extension KaraokeReadyStore {
    /// The default staleness check: re-stats `record.sourcePath` and compares its
    /// `(size, mtime)` against the record's stored fingerprint — the same fingerprint
    /// `SeparationCacheKey` hashes. A missing or changed file is stale (returns
    /// `false`). `nonisolated` so it can run off the main actor and serve as a default
    /// argument.
    nonisolated static func isFreshOnDisk(_ record: ReadyRecord) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: record.sourcePath) else {
            return false
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return size == record.sourceFileSize && mtime == record.sourceMTime
    }
}

private extension KaraokeReadyStore {
    /// Canonicalizes a file URL through the filesystem so aliases such as `/var` and
    /// `/private/var` match repository paths. Missing suffixes retain that canonical base.
    ///
    /// Delegates to ``CanonicalSourcePath`` — the SAME normalization
    /// ``InstrumentalCaching/remove(sourcePaths:)`` applies to both sides of its match,
    /// so a path this store calls ready is exactly the path the cache can remove.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        CanonicalSourcePath.canonical(url)
    }

    /// Canonicalizes a file-system path string the same way.
    nonisolated static func canonicalPath(_ path: String) -> String {
        CanonicalSourcePath.canonical(path)
    }
}
