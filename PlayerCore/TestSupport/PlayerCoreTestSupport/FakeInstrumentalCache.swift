// FakeInstrumentalCache — an in-memory ``InstrumentalCaching`` double.
//
// A deterministic, dependency-free stand-in for the real `InstrumentalCache`
// (todo 8): entries live in a plain dictionary, byte sizes are tracked in a side map
// (defaulting to the source file's on-disk size, or settable directly for eviction
// tests), and pins live in a `Set`. It performs NO real file copying — `store`
// records the source URL verbatim and hands it back. Seed it via `init(seeded:)` so
// XCUITest / view-model tests (todos 12, 15, 17) can drive a warm cache without the
// model. An `actor`, exactly like the production cache, so its async surface behaves
// identically to the real thing.
import Foundation
import Separation

/// An in-memory ``InstrumentalCaching`` for hermetic tests and previews.
public actor FakeInstrumentalCache: InstrumentalCaching {
    private var storage: [SeparationCacheKey: URL]
    private var byteSizes: [SeparationCacheKey: Int64]
    private var identities: [SeparationCacheKey: SourceIdentity] = [:]
    private var pinnedKeys: Set<SeparationCacheKey> = []
    private var sequence = 0
    private var onEntriesChanged: (@Sendable (Int, [ReadyRecord]) -> Void)?
    private var maxByteSize: Int64
    private var directory: URL?
    public private(set) var storeCallCount = 0
    public private(set) var clearCallCount = 0
    /// Every path handed to ``remove(sourcePaths:)``, in call order — including paths
    /// that matched nothing or were skipped as pinned, so a test can assert exactly what
    /// the UI asked for independently of what the cache actually deleted.
    public private(set) var removedSourcePaths: [String] = []

    /// Creates a cache pre-seeded with `seeded` (each entry's byte size starts at 0
    /// until overridden via ``setByteSize(_:for:)``).
    public init(seeded: [SeparationCacheKey: URL] = [:], maxByteSize: Int64 = 0) {
        storage = seeded
        byteSizes = seeded.mapValues { _ in 0 }
        self.maxByteSize = max(0, maxByteSize)
    }

    public func cachedInstrumental(for key: SeparationCacheKey) -> URL? {
        storage[key]
    }

    @discardableResult
    public func store(_ source: URL, for key: SeparationCacheKey, identity: SourceIdentity? = nil) throws -> URL {
        storeCallCount += 1
        storage[key] = source
        byteSizes[key] = Self.byteSizeOnDisk(of: source)
        if let identity {
            identities[key] = identity
        }
        emitEntriesChanged()
        return source
    }

    public func recordSourceIdentity(for key: SeparationCacheKey, identity: SourceIdentity) {
        guard storage[key] != nil else { return }
        identities[key] = identity
        emitEntriesChanged()
    }

    public func pin(_ key: SeparationCacheKey) {
        pinnedKeys.insert(key)
    }

    public func unpin(_ key: SeparationCacheKey) {
        pinnedKeys.remove(key)
    }

    public var totalBytes: Int64 {
        byteSizes.values.reduce(0, +)
    }

    public func clearAll() throws {
        clearCallCount += 1
        storage.removeAll()
        byteSizes.removeAll()
        pinnedKeys.removeAll()
        identities.removeAll()
        emitEntriesChanged()
    }

    /// Mirrors ``InstrumentalCache/remove(sourcePaths:)`` exactly: both sides
    /// canonicalized, pinned entries skipped, one change-seam emission per batch.
    @discardableResult
    public func remove(sourcePaths: [String]) throws -> Int {
        removedSourcePaths.append(contentsOf: sourcePaths)
        let targets = Set(sourcePaths.map(CanonicalSourcePath.canonical))
        guard !targets.isEmpty else { return 0 }

        let victims = storage.keys.filter { key in
            guard let identity = identities[key], !pinnedKeys.contains(key) else { return false }
            return targets.contains(CanonicalSourcePath.canonical(identity.path))
        }
        guard !victims.isEmpty else { return 0 }

        for key in victims {
            storage[key] = nil
            byteSizes[key] = nil
            identities[key] = nil
        }
        emitEntriesChanged()
        return victims.count
    }

    public func readySnapshot() -> (sequence: Int, records: [ReadyRecord]) {
        (sequence, readyRecords())
    }

    public func setOnEntriesChanged(_ handler: (@Sendable (Int, [ReadyRecord]) -> Void)?) {
        onEntriesChanged = handler
    }

    public func setMaxByteSize(_ newValue: Int64) {
        maxByteSize = max(0, newValue)
    }

    public func relocate(to newDirectory: URL) throws -> Bool {
        directory = newDirectory
        emitEntriesChanged()
        return true
    }

    // MARK: Inspection + configuration

    /// Whether `key` is currently pinned.
    public func isPinned(_ key: SeparationCacheKey) -> Bool {
        pinnedKeys.contains(key)
    }

    /// Whether `key` has a cached entry.
    public func contains(_ key: SeparationCacheKey) -> Bool {
        storage[key] != nil
    }

    /// Overrides the recorded byte size for `key` (drives eviction/size tests).
    public func setByteSize(_ bytes: Int64, for key: SeparationCacheKey) {
        byteSizes[key] = bytes
    }

    private func readyRecords() -> [ReadyRecord] {
        storage.keys.compactMap { key in
            guard let identity = identities[key] else { return nil }
            return ReadyRecord(
                sourcePath: identity.path,
                sourceFileSize: identity.fileSize,
                sourceMTime: identity.mtime,
                keyHex: key.hexValue
            )
        }
    }

    private func emitEntriesChanged() {
        sequence += 1
        onEntriesChanged?(sequence, readyRecords())
    }

    private static func byteSizeOnDisk(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
