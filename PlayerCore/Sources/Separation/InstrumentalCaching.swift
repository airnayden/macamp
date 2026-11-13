// InstrumentalCaching — the seam over the on-disk instrumental cache.
//
// Separation is expensive (seconds per track), so rendered instrumentals are cached
// content-addressed by ``SeparationCacheKey`` and reused. The production conformer
// (todo 8, `InstrumentalCache`) is an `actor` mirroring `ArtworkCache`'s design
// (content-addressed files + an `index.json` sidecar, LRU eviction over a byte cap,
// pinning). Every member is therefore `async`: an actor's isolated state is only
// reachable across the actor boundary with `await`. This file imports only
// Foundation and MUST NOT import AppKit/UIKit (PlayerCore portability invariant).
import Foundation

/// One enumerable "ready" instrumental: the source-file identity that produced it,
/// plus the cache-key hex that addresses it.
///
/// A ``SeparationCacheKey`` is a one-way digest, so the cache separately records the
/// plain source identity (``SourceIdentity``) on each entry; ``ReadyRecord`` is the
/// pair surfaced to consumers through ``InstrumentalCaching/readySnapshot()`` so they
/// can list the songs a warm cache can serve instantly. Legacy entries stored before
/// source identity was recorded carry no identity and are therefore excluded.
public struct ReadyRecord: Sendable, Equatable {
    /// The source file's path.
    public let sourcePath: String
    /// The source file's size in bytes.
    public let sourceFileSize: Int64
    /// The source file's modification time (seconds since 1970).
    public let sourceMTime: Double
    /// The ``SeparationCacheKey/hexValue`` addressing this instrumental.
    public let keyHex: String

    /// Creates a ready record.
    public init(sourcePath: String, sourceFileSize: Int64, sourceMTime: Double, keyHex: String) {
        self.sourcePath = sourcePath
        self.sourceFileSize = sourceFileSize
        self.sourceMTime = sourceMTime
        self.keyHex = keyHex
    }
}

/// A content-addressed cache of rendered instrumental files.
///
/// Keyed by ``SeparationCacheKey`` (file identity ⊕ model version) so a cache hit is
/// always valid for both the exact source file and the exact model. Conformers are
/// `Sendable`; the production one is an `actor` (hence the `async` surface).
public protocol InstrumentalCaching: Sendable {
    /// The cached instrumental URL for `key`, or `nil` on a miss. A hit MAY refresh
    /// the entry's LRU recency.
    func cachedInstrumental(for key: SeparationCacheKey) async -> URL?

    /// Stores the instrumental at `source` under `key`, returning the cache's own
    /// URL for it (callers should read back through the returned URL).
    ///
    /// - Parameter identity: The source file's identity (path/size/mtime) the
    ///   instrumental was rendered from, recorded on the entry so it can later be
    ///   enumerated through ``readySnapshot()``. `nil` records no identity (a legacy
    ///   or identity-less store), leaving the entry excluded from ready snapshots.
    /// - Throws: ``SeparationError/diskFull`` when the write runs out of space, or
    ///   ``SeparationError/encodeFailed`` for other write failures.
    @discardableResult
    func store(_ source: URL, for key: SeparationCacheKey, identity: SourceIdentity?) async throws -> URL

    /// Records the source identity for an existing cached entry and republishes the
    /// ready snapshot so legacy identity-less entries become enumerable.
    func recordSourceIdentity(for key: SeparationCacheKey, identity: SourceIdentity) async

    /// Pins `key` so it is exempt from LRU eviction (e.g. the active or pre-scheduled
    /// instrumental). Pinning a missing key is a no-op; safe to call repeatedly.
    func pin(_ key: SeparationCacheKey) async

    /// Removes a pin previously set by ``pin(_:)``. Unpinning a key that is not
    /// pinned is a no-op.
    func unpin(_ key: SeparationCacheKey) async

    /// The total size of all cached instrumentals, in bytes.
    var totalBytes: Int64 { get async }

    /// Removes every cached instrumental and empties the index.
    ///
    /// - Throws: A filesystem error if the cache directory cannot be cleared.
    func clearAll() async throws

    /// Removes the cached instrumentals rendered from `sourcePaths`, leaving the SOURCE
    /// files (and every database row describing them) untouched.
    ///
    /// Matching canonicalizes BOTH sides through ``CanonicalSourcePath``: entries record
    /// the `sourcePath` the render saw, while callers spell the same file however their
    /// own layer does, so a raw string comparison silently misses.
    ///
    /// A PINNED entry is skipped, never removed — a pin marks an instrumental the engine
    /// may be reading right now (the playing or pre-scheduled track), so yanking its file
    /// would break playback. Callers detect skips by comparing the returned count against
    /// the number of paths they asked for.
    ///
    /// The change-seam fires EXACTLY ONCE for the whole batch (not once per entry), so a
    /// multi-selection removal costs downstream consumers a single re-derivation.
    ///
    /// - Returns: The number of entries actually removed.
    /// - Throws: A filesystem error if a cached file cannot be removed.
    @discardableResult
    func remove(sourcePaths: [String]) async throws -> Int

    /// Atomically captures the current change-seam `sequence` together with the set
    /// of ready records — entries with a recorded source identity whose file still
    /// exists on disk. Returned together (never records-only) so a stale records read
    /// can never be tagged with a newer sequence.
    func readySnapshot() async -> (sequence: Int, records: [ReadyRecord])

    /// Installs (or clears with `nil`) the membership-change handler. It fires after
    /// every membership mutation (store, eviction, clear, relocate, dangling-entry
    /// drop) with a monotonically increasing `sequence` and the current ready records,
    /// so downstream consumers can drop out-of-order applications.
    func setOnEntriesChanged(_ handler: (@Sendable (_ sequence: Int, _ records: [ReadyRecord]) -> Void)?) async

    /// Updates the soft byte cap at runtime (clamped to `>= 0`). Decreasing it evicts
    /// down to the new cap immediately; `0` disables eviction (today's semantics).
    func setMaxByteSize(_ newValue: Int64) async

    /// Relocates the cache to `newDirectory`, copying every file first and only
    /// switching over once ALL copies succeed. On any copy failure the old directory
    /// is kept intact as the live cache and `false` is returned (nothing is lost).
    ///
    /// - Returns: `true` when the cache now lives at `newDirectory`; `false` when the
    ///   move failed and the cache is unchanged at its old directory.
    /// - Throws: A filesystem error only when the destination cannot be created.
    func relocate(to newDirectory: URL) async throws -> Bool
}
