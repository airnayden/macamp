// Contract for ``InstrumentalCache/remove(sourcePaths:)`` — the "Remove Karaoke Version"
// deletion path behind the karaoke ready list. Three properties are load-bearing and each
// has a test here: a PINNED (in-use) instrumental is never deleted, the change-seam fires
// EXACTLY ONCE per batch (not once per entry), and matching survives path-spelling
// differences (`/var` vs `/private/var`) because both sides canonicalize.
//
// Split from `InstrumentalCacheTests.swift` / `InstrumentalCacheReadySnapshotTests.swift`
// so each file stays within the SwiftLint file-length / type-body budgets.
import Foundation
@testable import Separation
import Testing

@Suite("InstrumentalCache targeted removal")
struct InstrumentalCacheRemovalTests {
    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstrumentalCacheRemovalTests-\(UUID().uuidString)")
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

    private static func sourceIdentity(_ path: String) -> SourceIdentity {
        SourceIdentity(path: path, fileSize: 1, mtime: 2)
    }

    private static func m4aFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".m4a") }
    }

    @Test("removing three sources deletes the two unpinned entries, keeps the pinned one, and fires the seam once")
    func removesUnpinnedSkipsPinnedAndEmitsOnce() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let paths = ["/m/a.flac", "/m/b.flac", "/m/c.flac"]
        let keys = paths.map(Self.key)
        for (path, key) in zip(paths, keys) {
            try await cache.store(Self.makeSource(bytes: 100), for: key, identity: Self.sourceIdentity(path))
        }
        await cache.pin(keys[2]) // the instrumental the engine may be reading right now

        // Install the recorder AFTER seeding so only the removal's emissions are counted.
        let recorder = SeamRecorder()
        await cache.setOnEntriesChanged { sequence, records in recorder.record(sequence, records) }

        let removed = try await cache.remove(sourcePaths: paths)

        #expect(removed == 2) // the pinned one is skipped, not counted
        #expect(await cache.entryCount() == 1)
        #expect(await cache.contains(keys[0]) == false)
        #expect(await cache.contains(keys[1]) == false)
        #expect(await cache.contains(keys[2])) // pinned: index entry AND file survive
        #expect(await cache.isPinned(keys[2])) // and its pin is left untouched

        let survivingFiles = try Self.m4aFiles(in: dir)
        #expect(survivingFiles == ["\(keys[2].hexValue).m4a"])

        #expect(recorder.events.count == 1) // ONE bump for the batch, not one per entry
        let payload = try #require(recorder.events.first)
        #expect(payload.records.map(\.keyHex) == [keys[2].hexValue])
    }

    /// The two "canonical" spellings of a temp file are OPPOSITES: production's
    /// `SeparationCacheKey.sourceIdentity` uses `resolvingSymlinksInPath()`, which STRIPS
    /// `/private` (→ `/var/…`), while `CanonicalSourcePath` uses `realpath(3)`, which adds
    /// it (→ `/private/var/…`). Neither side may be trusted to already match the other, so
    /// removal canonicalizes BOTH — proven here in both directions at once.
    @Test("a /var-spelled entry is removed by its /private/var spelling, and vice versa")
    func removesAcrossPrivateVarAliasSpelling() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let varSpelled = try Self.makeSource(bytes: 100)
        let privateVarSpelled = try Self.makeSource(bytes: 100)
        defer {
            try? FileManager.default.removeItem(at: varSpelled)
            try? FileManager.default.removeItem(at: privateVarSpelled)
        }

        let varIdentity = try SeparationCacheKey.sourceIdentity(for: varSpelled)
        let varKeyRemovedByPrivateVarPath = SeparationCacheKey(identity: varIdentity, modelSHA: "model")
        let privateVarPathOfVarEntry = CanonicalSourcePath.canonical(varSpelled)
        #expect(varIdentity.path != privateVarPathOfVarEntry)
        try await cache.store(varSpelled, for: varKeyRemovedByPrivateVarPath, identity: varIdentity)

        let mirrorIdentity = try SeparationCacheKey.sourceIdentity(for: privateVarSpelled)
        let mirrorKeyRemovedByVarPath = SeparationCacheKey(identity: mirrorIdentity, modelSHA: "model")
        let varPathOfPrivateVarEntry = mirrorIdentity.path
        try await cache.store(
            privateVarSpelled,
            for: mirrorKeyRemovedByVarPath,
            identity: SourceIdentity(
                path: CanonicalSourcePath.canonical(privateVarSpelled),
                fileSize: mirrorIdentity.fileSize,
                mtime: mirrorIdentity.mtime
            )
        )

        let removed = try await cache.remove(
            sourcePaths: [privateVarPathOfVarEntry, varPathOfPrivateVarEntry]
        )

        #expect(removed == 2)
        #expect(await cache.contains(varKeyRemovedByPrivateVarPath) == false)
        #expect(await cache.contains(mirrorKeyRemovedByVarPath) == false)
        #expect(await cache.entryCount() == 0)
        let survivingFiles = try Self.m4aFiles(in: dir)
        #expect(survivingFiles.isEmpty)
    }

    @Test("paths with no cached entry remove nothing, return zero, and never fire the seam")
    func unknownPathsRemoveNothingAndDoNotEmit() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let key = Self.key("/m/a.flac")
        try await cache.store(Self.makeSource(bytes: 100), for: key, identity: Self.sourceIdentity("/m/a.flac"))
        let recorder = SeamRecorder()
        await cache.setOnEntriesChanged { sequence, records in recorder.record(sequence, records) }

        let removedUnknown = try await cache.remove(sourcePaths: ["/m/never-rendered.flac"])
        let removedEmpty = try await cache.remove(sourcePaths: [])

        #expect(removedUnknown == 0)
        #expect(removedEmpty == 0)
        #expect(await cache.contains(key)) // the unrelated entry is untouched
        #expect(recorder.events.isEmpty) // a no-op removal must not churn consumers
    }
}

/// A thread-safe recorder for the `@Sendable` change-seam handler.
private final class SeamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(sequence: Int, records: [ReadyRecord])] = []

    func record(_ sequence: Int, _ records: [ReadyRecord]) {
        lock.withLock { storage.append((sequence, records)) }
    }

    var events: [(sequence: Int, records: [ReadyRecord])] {
        lock.withLock { storage }
    }
}
