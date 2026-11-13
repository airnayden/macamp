// Behaviour contract for ``InstrumentalCache`` — the content-addressed disk cache that
// makes karaoke playback affordable by reusing rendered instrumentals. Downstream todos
// (9 pipeline store, 12 coordinator resolution, 13 pre-warm) depend on: dedupe by key,
// LRU eviction in exact recency order, pin exemption, clearAll, warm-load across re-init,
// and graceful recovery from a corrupted index. The injected clock makes LRU ordering
// deterministic without touching wall-clock time.
//
// The source-identity, ready-snapshot/change-seam, runtime-cap, and safe-relocation
// contract lives in `InstrumentalCacheReadySnapshotTests.swift` (file/type-body budget).
import Foundation
@testable import Separation
import Testing

@Suite("InstrumentalCache")
struct InstrumentalCacheTests {
    @Test("A result that cannot fit is rejected without evicting existing pinned audio", arguments: [30, 200])
    func rejectsResultThatCannotFit(bytes: Int) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existingSource = try Self.makeSource(bytes: 80)
        let newSource = try Self.makeSource(bytes: bytes)
        defer {
            try? FileManager.default.removeItem(at: existingSource)
            try? FileManager.default.removeItem(at: newSource)
        }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 100)
        let existingKey = Self.key("/existing.flac")
        let existing = try await cache.store(existingSource, for: existingKey)
        await cache.pin(existingKey)

        do {
            _ = try await cache.store(newSource, for: Self.key("/new.flac"))
            Issue.record("An output that cannot fit must fail explicitly")
        } catch {
            #expect(error as? SeparationError == .cacheCapacityExceeded)
            #expect(await cache.entryCount() == 1)
        }
        #expect(FileManager.default.fileExists(atPath: existing.path))
        #expect(await cache.totalBytes == 80)
        #expect(try Self.m4aFiles(in: dir).count == 1)
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstrumentalCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A throwaway source file of `bytes` bytes, outside any cache directory.
    private static func makeSource(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("instrumental-source-\(UUID().uuidString).m4a")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private static func key(_ path: String) -> SeparationCacheKey {
        SeparationCacheKey(canonicalPath: path, fileSize: 1, mtime: 2, modelSHA: "model")
    }

    private static func m4aFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".m4a") }
    }

    @Test("storing the same key twice keeps one file and counts its bytes once")
    func dedupesSameKey() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let source = try Self.makeSource(bytes: 200)
        let keyA = Self.key("/music/a.flac")

        let first = try await cache.store(source, for: keyA)
        let second = try await cache.store(source, for: keyA)

        #expect(first == second) // same content-addressed URL
        #expect(await cache.entryCount() == 1) // one index entry
        #expect(await cache.totalBytes == 200) // counted once, not 400
        #expect(try Self.m4aFiles(in: dir).count == 1) // one physical file
    }

    @Test("inserting past the cap evicts least-recently-used first, in exact order")
    func evictsLRUFirstInExactOrder() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Cap holds exactly two 100-byte instrumentals; the injected clock stamps
        // recency 1, 2, 3, … in store/lookup order for a deterministic victim.
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 250, clock: { $0 + 1 })
        let keyA = Self.key("/m/a.flac")
        let keyB = Self.key("/m/b.flac")
        let keyC = Self.key("/m/c.flac")
        let keyD = Self.key("/m/d.flac")

        try await cache.store(Self.makeSource(bytes: 100), for: keyA) // clock 1
        try await cache.store(Self.makeSource(bytes: 100), for: keyB) // clock 2
        try await cache.store(Self.makeSource(bytes: 100), for: keyC) // clock 3 → 300 > 250, evict A

        #expect(await cache.contains(keyA) == false) // oldest → evicted first
        #expect(await cache.contains(keyB))
        #expect(await cache.contains(keyC))

        // A lookup refreshes B's recency, so C becomes the oldest and next victim.
        _ = await cache.cachedInstrumental(for: keyB) // clock 4 → B is now MRU
        try await cache.store(Self.makeSource(bytes: 100), for: keyD) // clock 5 → 300 > 250, evict C

        #expect(await cache.contains(keyC) == false) // LRU after B's refresh → evicted
        #expect(await cache.contains(keyB)) // survived via the lookup refresh
        #expect(await cache.contains(keyD))
        #expect(await cache.totalBytes <= 250)
    }

    @Test("a pinned entry survives eviction pressure even when it is the oldest")
    func pinnedSurvivesEviction() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 250, clock: { $0 + 1 })
        let keyA = Self.key("/m/a.flac") // will be the oldest
        let keyB = Self.key("/m/b.flac")
        let keyC = Self.key("/m/c.flac")

        try await cache.store(Self.makeSource(bytes: 100), for: keyA)
        try await cache.store(Self.makeSource(bytes: 100), for: keyB)
        await cache.pin(keyA) // exempt the oldest from eviction
        try await cache.store(Self.makeSource(bytes: 100), for: keyC) // 300 > 250 → evict B, not A

        #expect(await cache.contains(keyA)) // pinned oldest → survives
        #expect(await cache.contains(keyB) == false) // next-oldest unpinned → evicted
        #expect(await cache.contains(keyC))
        #expect(await cache.isPinned(keyA))
    }

    @Test("clearAll removes every file, empties the index and drops pins")
    func clearAllEmptiesEverything() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let keyA = Self.key("/m/a.flac")
        try await cache.store(Self.makeSource(bytes: 128), for: keyA)
        await cache.pin(keyA)

        try await cache.clearAll()

        #expect(await cache.entryCount() == 0)
        #expect(await cache.totalBytes == 0)
        #expect(await cache.cachedInstrumental(for: keyA) == nil)
        #expect(await cache.isPinned(keyA) == false)
        #expect(try Self.m4aFiles(in: dir).isEmpty)
    }

    @Test("a fresh cache over the same directory warm-loads the on-disk index")
    func warmLoadsAcrossReinit() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyA = Self.key("/m/warm.flac")

        let storedURL: URL
        do {
            let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
            storedURL = try await cache.store(Self.makeSource(bytes: 256), for: keyA)
        }

        // A brand-new instance over the same directory must see the prior instrumental.
        let warm = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        #expect(await warm.entryCount() == 1)
        #expect(await warm.totalBytes == 256)
        #expect(await warm.cachedInstrumental(for: keyA) == storedURL)
        #expect(await warm.contains(keyA))
    }

    @Test("a corrupted index.json rebuilds an empty cache without crashing")
    func corruptedIndexRebuildsEmpty() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Write garbage where index.json is expected.
        try Data("{ not valid json ".utf8).write(to: dir.appendingPathComponent("index.json"))

        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        #expect(await cache.entryCount() == 0) // rebuilt empty, no crash
        #expect(await cache.totalBytes == 0)

        // And it still works — a store after the corrupted load succeeds and warm-loads.
        let keyA = Self.key("/m/a.flac")
        let url = try await cache.store(Self.makeSource(bytes: 64), for: keyA)
        #expect(await cache.cachedInstrumental(for: keyA) == url)
        #expect(await cache.entryCount() == 1)
    }

    @Test("storing from a missing source maps the write failure to encodeFailed")
    func storeMissingSourceThrowsEncodeFailed() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).m4a")

        await #expect(throws: SeparationError.encodeFailed) {
            _ = try await cache.store(missing, for: Self.key("/m/a.flac"))
        }
        #expect(await cache.entryCount() == 0) // a failed store records nothing
    }
}
