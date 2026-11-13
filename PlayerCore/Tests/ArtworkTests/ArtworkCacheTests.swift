@testable import Artwork
import Foundation
import Testing

@Suite("ArtworkCacheTests")
struct ArtworkCacheTests {
    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func album(_ name: String) -> ArtworkRequest.AlbumKey {
        ArtworkRequest.AlbumKey(artist: "Artist", album: name)
    }

    @Test("LRU eviction drops the oldest blob past the cap; a touched blob survives")
    func lruEvictsOldestKeepsTouched() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Cap holds exactly three 100-byte blobs.
        let cache = try ArtworkCache(directory: dir, maxByteSize: 300)

        let hash1 = try await cache.store(
            data: Data(repeating: 1, count: 100),
            source: .embedded,
            for: Self.album("one")
        )
        let hash2 = try await cache.store(
            data: Data(repeating: 2, count: 100),
            source: .embedded,
            for: Self.album("two")
        )
        let hash3 = try await cache.store(
            data: Data(repeating: 3, count: 100),
            source: .embedded,
            for: Self.album("three")
        )

        // Promote blob1 to most-recently-used so blob2 becomes the LRU victim.
        await cache.touch(hash: hash1)
        let hash4 = try await cache.store(
            data: Data(repeating: 4, count: 100),
            source: .embedded,
            for: Self.album("four")
        )

        let has1 = await cache.contains(hash: hash1)
        let has2 = await cache.contains(hash: hash2)
        let has3 = await cache.contains(hash: hash3)
        let has4 = await cache.contains(hash: hash4)
        let total = await cache.currentByteSize()

        #expect(has1) // touched → survives
        #expect(has2 == false) // oldest untouched → evicted
        #expect(has3)
        #expect(has4)
        #expect(total <= 300)
    }

    @Test("identical bytes under two albums are stored once (dedupe by content hash)")
    func dedupesIdenticalBytesAcrossAlbums() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try ArtworkCache(directory: dir, maxByteSize: 10000)
        let shared = Data(repeating: 7, count: 256)

        let hashA = try await cache.store(data: shared, source: .embedded, for: Self.album("A"))
        let hashB = try await cache.store(data: shared, source: .embedded, for: Self.album("B"))

        let count = await cache.blobCount()
        let total = await cache.currentByteSize()
        let fromA = await cache.cachedHash(for: Self.album("A"))
        let fromB = await cache.cachedHash(for: Self.album("B"))

        #expect(hashA == hashB)
        #expect(count == 1) // one physical blob
        #expect(total == 256) // not 512
        #expect(fromA == hashA)
        #expect(fromB == hashB)
    }

    @Test("a fresh cache instance warm-loads blobs from the on-disk index")
    func warmLoadsFromIndexOnDisk() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stored: String
        do {
            let cache = try ArtworkCache(directory: dir, maxByteSize: 10000)
            stored = try await cache.store(
                data: Data(repeating: 9, count: 128),
                source: .itunes,
                for: Self.album("warm")
            )
        }

        // A brand-new instance over the same directory must see the prior blob.
        let warm = try ArtworkCache(directory: dir, maxByteSize: 10000)
        let has = await warm.contains(hash: stored)
        let count = await warm.blobCount()
        let art = await warm.cachedArtwork(for: Self.album("warm"))

        #expect(has)
        #expect(count == 1)
        #expect(art?.contentHash == stored)
        #expect(art?.source == .cache)
        #expect(art?.data.count == 128)
    }
}
