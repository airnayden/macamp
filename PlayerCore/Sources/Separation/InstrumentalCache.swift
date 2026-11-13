// InstrumentalCache — a content-addressed, size-capped disk cache for rendered
// instrumentals, mirroring `ArtworkCache`'s design one module over.
//
// Separation is expensive (seconds per track), so a rendered instrumental is cached
// keyed by ``SeparationCacheKey`` (source-file identity ⊕ model version) and reused.
// Like `ArtworkCache` it is:
//   * CONTENT-ADDRESSED — each instrumental is stored as `<key>.m4a`, so the same
//     source + model always maps to the same file and a re-render is a no-op.
//   * LRU-EVICTING — once the on-disk total exceeds the byte cap the
//     least-recently-used files are dropped until it fits again; a lookup refreshes
//     recency, and a PINNED entry (the active / pre-scheduled instrumental) is exempt.
//   * WARM-LOADING — an `index.json` sidecar records every entry's key, file name,
//     size, recency and model SHA, so a freshly-constructed cache over the same
//     directory immediately sees previously rendered instrumentals.
//
// It is an `actor`: all mutation of the index + filesystem is serialised, so the
// pipeline (todo 9), coordinator (todo 12) and pre-warm service (todo 13) can hit it
// concurrently. Foundation-only — no AppKit/UIKit (PlayerCore portability invariant),
// and NO GRDB (this cache is filesystem + JSON sidecar, exactly like `ArtworkCache`).
import Foundation

/// A size-capped, content-addressed on-disk cache of rendered instrumentals with LRU
/// eviction and pinning.
public actor InstrumentalCache: InstrumentalCaching {
    /// Per-instrumental bookkeeping persisted in `index.json`.
    struct Entry: Codable {
        /// The ``SeparationCacheKey/hexValue`` this instrumental was rendered for.
        var key: String
        /// The instrumental's file name **relative to the cache directory** (`<key>.m4a`),
        /// so the cache directory stays relocatable.
        var filePath: String
        /// The instrumental's size on disk, in bytes.
        var bytes: Int64
        /// Monotonic recency stamp (from the injected clock); higher = more recent.
        var lruClock: Int
        /// The separation model SHA the instrumental was rendered with (diagnostic /
        /// future invalidation; the key already folds the model version in via XOR).
        var modelSHA: String
        /// Source-file identity (path/size/mtime) this instrumental was rendered from.
        /// **Optional** so a legacy `index.json` written before identity was recorded
        /// still decodes — a required field would fail the decode and wipe the index via
        /// the empty-index fallback. `nil` ⇒ excluded from ``readySnapshot()``.
        var sourcePath: String?
        var sourceFileSize: Int64?
        var sourceMTime: Double?
    }

    /// The persisted cache index: entries keyed by ``SeparationCacheKey/hexValue``.
    struct Index: Codable {
        var entries: [String: Entry] = [:]
    }

    /// The default byte cap: 2 GB.
    public static let defaultByteCap: Int64 = 2 * 1024 * 1024 * 1024

    // The members reached by `InstrumentalCache+Relocation.swift` are `internal`
    // (not `private`) so that extension can live in its own file (budget).
    var directory: URL
    private var maxByteSize: Int64
    private let modelSHA: String
    let fileManager: FileManager
    /// Advances the logical recency clock (current → next). Injected so tests get
    /// deterministic LRU ordering without touching wall-clock time; defaults to a plain
    /// monotonic increment, exactly like `ArtworkCache`'s internal clock.
    private let advanceClock: @Sendable (Int) -> Int
    var index: Index
    /// Monotonic recency clock — seeded from the persisted maximum so warm-loaded
    /// entries keep their relative order, then advanced on every store/lookup.
    private var clock: Int
    /// Runtime-only eviction exemptions (hex keys). NOT persisted: the active /
    /// pre-scheduled instrumentals are re-pinned by the coordinator (todo 12) on launch.
    /// `internal` so `InstrumentalCache+Removal.swift` can honour the same exemption.
    var pinnedKeys: Set<String> = []
    /// Monotonic change-seam counter, bumped on every membership mutation so downstream
    /// consumers can drop out-of-order snapshot applications. Read back atomically with
    /// the records by ``readySnapshot()``.
    private var sequence = 0
    /// Fired after every membership mutation with the bumped ``sequence`` and current
    /// ready records; `nil` until a consumer installs it via ``setOnEntriesChanged(_:)``.
    private var onEntriesChanged: (@Sendable (Int, [ReadyRecord]) -> Void)?

    /// - Parameters:
    ///   - directory: Folder that holds the `<key>.m4a` files and `index.json`. Created
    ///     if absent.
    ///   - maxByteSize: Soft cap on the total instrumental bytes; `0` disables eviction.
    ///     Defaults to ``defaultByteCap`` (2 GB).
    ///   - modelSHA: The separation model SHA stamped onto entries stored by this cache
    ///     (diagnostic; the key already encodes model identity). Defaults to empty.
    ///   - clock: Advances the recency clock (current → next); injected for deterministic
    ///     tests. Defaults to a monotonic increment.
    public init(
        directory: URL,
        maxByteSize: Int64 = InstrumentalCache.defaultByteCap,
        modelSHA: String = "",
        clock: @escaping @Sendable (Int) -> Int = { $0 + 1 }
    ) throws {
        self.directory = directory
        self.maxByteSize = max(0, maxByteSize)
        self.modelSHA = modelSHA
        advanceClock = clock
        fileManager = .default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        index = Self.loadIndex(from: Self.indexURL(in: directory), fileManager: .default)
        self.clock = index.entries.values.map(\.lruClock).max() ?? 0
    }

    // MARK: Store

    /// Copies the instrumental at `source` into the cache under `key`, returning the
    /// cache's own URL for it. Dedupes by key (a re-render of the same source + model is
    /// a no-op that just refreshes recency), then evicts down to the cap and persists.
    ///
    /// - Throws: ``SeparationError/cacheCapacityExceeded`` when the output cannot fit
    ///   beside pinned audio, ``SeparationError/diskFull`` when the copy runs out of space, or
    ///   ``SeparationError/encodeFailed`` for any other write failure.
    @discardableResult
    public func store(_ source: URL, for key: SeparationCacheKey, identity: SourceIdentity? = nil) throws -> URL {
        try Task.checkCancellation()
        let destination = fileURL(for: key)
        clock = advanceClock(clock)
        if index.entries[key.hexValue] != nil, fileManager.fileExists(atPath: destination.path) {
            index.entries[key.hexValue]?.lruClock = clock
            applyIdentity(identity, to: key.hexValue)
            try persist()
            emitEntriesChanged()
            return destination
        }
        try copyIntoCache(from: source, to: destination)
        do {
            try Task.checkCancellation()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        let bytes = Self.byteSize(of: destination, fileManager: fileManager)
        let pinnedBytes = index.entries.values
            .filter { pinnedKeys.contains($0.key) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        if maxByteSize > 0, !pinnedKeys.contains(key.hexValue),
           bytes > maxByteSize || pinnedBytes > maxByteSize - bytes
        {
            try fileManager.removeItem(at: destination)
            throw SeparationError.cacheCapacityExceeded
        }
        index.entries[key.hexValue] = Entry(
            key: key.hexValue,
            filePath: destination.lastPathComponent,
            bytes: bytes,
            lruClock: clock,
            modelSHA: modelSHA,
            sourcePath: identity?.path,
            sourceFileSize: identity?.fileSize,
            sourceMTime: identity?.mtime
        )
        try evictIfNeeded(protecting: key.hexValue)
        try persist()
        emitEntriesChanged()
        return destination
    }

    public func recordSourceIdentity(for key: SeparationCacheKey, identity: SourceIdentity) {
        guard index.entries[key.hexValue] != nil else { return }
        applyIdentity(identity, to: key.hexValue)
        try? persist()
        emitEntriesChanged()
    }

    /// A `nil` identity leaves any previously-recorded identity untouched.
    private func applyIdentity(_ identity: SourceIdentity?, to hexKey: String) {
        guard let identity else { return }
        index.entries[hexKey]?.sourcePath = identity.path
        index.entries[hexKey]?.sourceFileSize = identity.fileSize
        index.entries[hexKey]?.sourceMTime = identity.mtime
    }

    // MARK: Lookup

    /// The cached instrumental URL for `key`, or `nil` on a miss. A hit refreshes the
    /// entry's LRU recency; a dangling entry (file gone) is dropped and reported as a miss.
    public func cachedInstrumental(for key: SeparationCacheKey) -> URL? {
        guard let entry = index.entries[key.hexValue] else { return nil }
        let url = directory.appendingPathComponent(entry.filePath)
        guard fileManager.fileExists(atPath: url.path) else {
            index.entries[key.hexValue] = nil
            try? persist()
            emitEntriesChanged()
            return nil
        }
        clock = advanceClock(clock)
        index.entries[key.hexValue]?.lruClock = clock
        try? persist()
        return url
    }

    // MARK: Pinning

    /// Pins `key` so it is exempt from LRU eviction. A no-op for a missing key; safe to
    /// call repeatedly. Pins are runtime-only and reset on a cold start.
    public func pin(_ key: SeparationCacheKey) {
        pinnedKeys.insert(key.hexValue)
    }

    /// Removes a pin previously set by ``pin(_:)``. A no-op if `key` was not pinned.
    public func unpin(_ key: SeparationCacheKey) {
        pinnedKeys.remove(key.hexValue)
    }

    // MARK: Size + clear

    /// The total size of all cached instrumentals, in bytes.
    public var totalBytes: Int64 {
        index.entries.values.reduce(0) { $0 + $1.bytes }
    }

    /// Removes every cached instrumental, empties the index and clears all pins.
    ///
    /// - Throws: A filesystem error if a cached file cannot be removed.
    public func clearAll() throws {
        for entry in index.entries.values {
            let url = directory.appendingPathComponent(entry.filePath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        index = Index()
        pinnedKeys.removeAll()
        try persist()
        emitEntriesChanged()
    }

    // MARK: Ready snapshot + change seam

    /// The current change-seam sequence and ready records, captured together in this
    /// single actor hop so a stale records read can never be paired with a newer
    /// sequence (todo 6's reorder guard relies on this atomicity).
    public func readySnapshot() -> (sequence: Int, records: [ReadyRecord]) {
        (sequence, readyRecords())
    }

    public func setOnEntriesChanged(_ handler: (@Sendable (Int, [ReadyRecord]) -> Void)?) {
        onEntriesChanged = handler
    }

    /// Entries with a recorded source identity whose file still exists on disk; legacy
    /// identity-less entries are excluded (their key is a one-way hash — they become
    /// enumerable only after their next render records an identity).
    private func readyRecords() -> [ReadyRecord] {
        index.entries.values.compactMap { entry in
            guard
                let sourcePath = entry.sourcePath,
                let sourceFileSize = entry.sourceFileSize,
                let sourceMTime = entry.sourceMTime,
                fileManager.fileExists(atPath: directory.appendingPathComponent(entry.filePath).path)
            else { return nil }
            return ReadyRecord(
                sourcePath: sourcePath,
                sourceFileSize: sourceFileSize,
                sourceMTime: sourceMTime,
                keyHex: entry.key
            )
        }
    }

    func emitEntriesChanged() {
        sequence += 1
        onEntriesChanged?(sequence, readyRecords())
    }

    public func setMaxByteSize(_ newValue: Int64) {
        maxByteSize = max(0, newValue)
        let didEvict = (try? evictIfNeeded()) ?? false
        guard didEvict else { return }
        try? persist()
        emitEntriesChanged()
    }

    // MARK: Inspection (tests + diagnostics)

    /// The number of instrumentals currently indexed.
    public func entryCount() -> Int {
        index.entries.count
    }

    /// `true` when `key` has an index entry AND its file exists on disk.
    public func contains(_ key: SeparationCacheKey) -> Bool {
        guard let entry = index.entries[key.hexValue] else { return false }
        return fileManager.fileExists(atPath: directory.appendingPathComponent(entry.filePath).path)
    }

    /// `true` when `key` is currently pinned (exempt from eviction).
    public func isPinned(_ key: SeparationCacheKey) -> Bool {
        pinnedKeys.contains(key.hexValue)
    }

    // MARK: Eviction + persistence

    @discardableResult
    private func evictIfNeeded(protecting protectedKey: String? = nil) throws -> Bool {
        guard maxByteSize > 0 else { return false }
        var total = totalBytes
        guard total > maxByteSize else { return false }
        // Oldest-first over the UNPINNED entries; pinned instrumentals are exempt even
        // when they are the least-recently-used.
        let victims = index.entries.values
            .filter { !pinnedKeys.contains($0.key) && $0.key != protectedKey }
            .sorted { $0.lruClock < $1.lruClock }
        var removedAny = false
        for entry in victims {
            guard total > maxByteSize else { break }
            try removeEntry(entry)
            total -= entry.bytes
            removedAny = true
        }
        return removedAny
    }

    func removeEntry(_ entry: Entry) throws {
        let url = directory.appendingPathComponent(entry.filePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        index.entries[entry.key] = nil
    }

    private func copyIntoCache(from source: URL, to destination: URL) throws {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw Self.mapWriteError(error)
        }
    }

    func persist() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: Self.indexURL(in: directory), options: .atomic)
    }

    private func fileURL(for key: SeparationCacheKey) -> URL {
        directory.appendingPathComponent("\(key.hexValue).m4a")
    }

    // MARK: Static helpers

    static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }

    /// Warm-loads the index, returning an EMPTY index when the sidecar is absent or
    /// corrupted — a bad `index.json` rebuilds an empty cache, never crashes.
    private static func loadIndex(from url: URL, fileManager: FileManager) -> Index {
        guard
            fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Index.self, from: data)
        else { return Index() }
        return decoded
    }

    private static func byteSize(of url: URL, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Maps a filesystem write failure onto the pipeline's typed error: out-of-space →
    /// ``SeparationError/diskFull``, everything else → ``SeparationError/encodeFailed``.
    private static func mapWriteError(_ error: Error) -> SeparationError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .diskFull
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC)
        {
            return .diskFull
        }
        return .encodeFailed
    }
}
