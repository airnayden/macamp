// Source-identity, ready-snapshot/change-seam, runtime-cap, and safe-relocation contract
// for ``InstrumentalCache`` — the todo-2 hardening surface that downstream karaoke todos
// (6 KaraokeReadyStore reorder guard, 11 composition, 12 coordinator, 14 ready list)
// depend on. Split out of `InstrumentalCacheTests.swift` so each file stays within the
// SwiftLint file-length / type-body budgets; the classic cache behaviour (dedupe, LRU,
// pin, clearAll, warm-load, corrupted-index) lives in that sibling file.
import Foundation
@testable import Separation
import Testing

@Suite("InstrumentalCache source identity, ready snapshot & relocation")
struct InstrumentalCacheReadySnapshotTests {
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

    private static func sourceIdentity(_ path: String, size: Int64 = 1, mtime: Double = 2) -> SourceIdentity {
        SourceIdentity(path: path, fileSize: size, mtime: mtime)
    }

    private static func m4aFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".m4a") }
    }

    @Test(
        "(a) a legacy index.json without source-identity fields still decodes, serves by key, and is excluded from readySnapshot"
    )
    func legacyIndexWithoutSourceFieldsDecodesServesButNotReady() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = Self.key("/m/legacy.flac")
        let fileName = "\(key.hexValue).m4a"
        try Data(repeating: 0xCD, count: 128).write(to: dir.appendingPathComponent(fileName))
        // A pre-source-identity sidecar: key/filePath/bytes/lruClock/modelSHA, NO source fields.
        let legacyIndex = """
        {"entries":{"\(key.hexValue)":{"key":"\(key
            .hexValue)","filePath":"\(fileName)","bytes":128,"lruClock":5,"modelSHA":"legacy"}}}
        """
        try Data(legacyIndex.utf8).write(to: dir.appendingPathComponent("index.json"))

        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)

        #expect(await cache.entryCount() == 1) // decoded, NOT wiped by the empty-index fallback
        #expect(await cache.cachedInstrumental(for: key) != nil) // still servable by key
        #expect(await cache.readySnapshot().records.isEmpty) // excluded: no recorded source identity
    }

    @Test("(b) storing with a source identity surfaces the entry in readySnapshot")
    func storeWithIdentityAppearsInReadySnapshot() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let key = Self.key("/m/a.flac")

        try await cache.store(
            Self.makeSource(bytes: 200),
            for: key,
            identity: Self.sourceIdentity("/m/a.flac", size: 4242, mtime: 111)
        )

        let snapshot = await cache.readySnapshot()
        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(record.sourcePath == "/m/a.flac")
        #expect(record.sourceFileSize == 4242)
        #expect(record.sourceMTime == 111)
        #expect(record.keyHex == key.hexValue)
    }

    @Test("(c) clearAll fires the seam with an empty record set and a higher sequence")
    func clearAllFiresSeamEmptyWithHigherSequence() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let recorder = SeamRecorder()
        let key = Self.key("/m/a.flac")
        try await cache.store(Self.makeSource(bytes: 128), for: key, identity: Self.sourceIdentity("/m/a.flac"))
        await cache.setOnEntriesChanged { sequence, records in recorder.record(sequence, records) }
        let sequenceBeforeClear = await cache.readySnapshot().sequence

        try await cache.clearAll()

        let last = try #require(recorder.events.last)
        #expect(last.records.isEmpty)
        #expect(last.sequence > sequenceBeforeClear)
        #expect(await cache.readySnapshot().records.isEmpty)
    }

    @Test("(d) eviction past the cap fires the seam without the evicted victim")
    func evictionFiresSeamWithoutVictim() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 250, clock: { $0 + 1 })
        let recorder = SeamRecorder()
        await cache.setOnEntriesChanged { sequence, records in recorder.record(sequence, records) }
        let keyA = Self.key("/m/a.flac")
        let keyB = Self.key("/m/b.flac")
        let keyC = Self.key("/m/c.flac")

        try await cache.store(Self.makeSource(bytes: 100), for: keyA, identity: Self.sourceIdentity("/m/a.flac"))
        try await cache.store(Self.makeSource(bytes: 100), for: keyB, identity: Self.sourceIdentity("/m/b.flac"))
        try await cache.store(Self.makeSource(bytes: 100), for: keyC, identity: Self.sourceIdentity("/m/c.flac"))

        #expect(await cache.contains(keyA) == false) // oldest evicted
        let last = try #require(recorder.events.last)
        let hexes = Set(last.records.map(\.keyHex))
        #expect(hexes.contains(keyA.hexValue) == false) // seam's last payload excludes the victim
        #expect(hexes.contains(keyB.hexValue))
        #expect(hexes.contains(keyC.hexValue))
    }

    @Test("(e) setMaxByteSize shrinks immediately with pins exempt; zero disables eviction")
    func setMaxByteSizeShrinksImmediatelyAndZeroDisables() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 0, clock: { $0 + 1 }) // unbounded
        let keyA = Self.key("/m/a.flac")
        let keyB = Self.key("/m/b.flac")
        let keyC = Self.key("/m/c.flac")
        try await cache.store(Self.makeSource(bytes: 100), for: keyA)
        try await cache.store(Self.makeSource(bytes: 100), for: keyB)
        try await cache.store(Self.makeSource(bytes: 100), for: keyC)
        await cache.pin(keyA) // pin the oldest so shrinking cannot evict it

        await cache.setMaxByteSize(150)

        #expect(await cache.totalBytes <= 150) // shrank down to the new cap at once
        #expect(await cache.contains(keyA)) // pinned oldest exempt
        #expect(await cache.isPinned(keyA))

        await cache.setMaxByteSize(0) // restore "no eviction"
        let countBefore = await cache.entryCount()
        try await cache.store(Self.makeSource(bytes: 100_000), for: Self.key("/m/huge.flac"))
        #expect(await cache.entryCount() == countBefore + 1) // far beyond old cap, yet nothing evicted
    }

    @Test(
        "(f) sequences strictly increase across interleaved store/clear and readySnapshot matches the last fired sequence"
    )
    func sequencesStrictlyIncreaseAndSnapshotMatchesLastFired() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try InstrumentalCache(directory: dir, maxByteSize: 10000)
        let recorder = SeamRecorder()
        await cache.setOnEntriesChanged { sequence, records in recorder.record(sequence, records) }

        try await cache.store(
            Self.makeSource(bytes: 50),
            for: Self.key("/m/a.flac"),
            identity: Self.sourceIdentity("/m/a.flac")
        )
        try await cache.store(
            Self.makeSource(bytes: 50),
            for: Self.key("/m/b.flac"),
            identity: Self.sourceIdentity("/m/b.flac")
        )
        try await cache.clearAll()
        try await cache.store(
            Self.makeSource(bytes: 50),
            for: Self.key("/m/c.flac"),
            identity: Self.sourceIdentity("/m/c.flac")
        )

        let sequences = recorder.events.map(\.sequence)
        #expect(sequences == sequences.sorted()) // monotonic
        #expect(Set(sequences).count == sequences.count) // strictly increasing (no repeats)
        let snapshot = await cache.readySnapshot()
        #expect(snapshot.sequence == recorder.lastSequence) // atomicity: snapshot sequence == last fired
    }

    @Test(
        "(g) relocate copies everything, keeps lookups working, leaves the snapshot unchanged, and empties the old directory"
    )
    func relocateHappyPathMovesEverything() async throws {
        let oldDir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: oldDir) }
        let newDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstrumentalCacheReloc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: newDir) }

        let cache = try InstrumentalCache(directory: oldDir, maxByteSize: 10000)
        let keyA = Self.key("/m/a.flac")
        let keyB = Self.key("/m/b.flac")
        try await cache.store(Self.makeSource(bytes: 100), for: keyA, identity: Self.sourceIdentity("/m/a.flac"))
        try await cache.store(Self.makeSource(bytes: 100), for: keyB, identity: Self.sourceIdentity("/m/b.flac"))
        let before = await cache.readySnapshot()

        let moved = try await cache.relocate(to: newDir)

        #expect(moved)
        #expect(try Self.m4aFiles(in: newDir).count == 2) // both files copied over
        #expect(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("index.json").path))
        let hitA = await cache.cachedInstrumental(for: keyA)
        #expect(hitA?.path.hasPrefix(newDir.path) == true) // lookups now resolve under the new dir
        #expect(hitA.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        let after = await cache.readySnapshot()
        #expect(after.records.sorted { $0.keyHex < $1.keyHex } == before.records.sorted { $0.keyHex < $1.keyHex })
        #expect(try Self.m4aFiles(in: oldDir).isEmpty) // old dir emptied of instrumentals
    }

    @Test(
        "(h) an injected copy failure during relocate returns false, keeps the old directory serving, leaves the snapshot unchanged, and drops no partial files"
    )
    func relocateCopyFailureKeepsOldDirectoryIntact() async throws {
        let oldDir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: oldDir) }
        let newDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstrumentalCacheRelocFail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: newDir.path)
            try? FileManager.default.removeItem(at: newDir)
        }

        let cache = try InstrumentalCache(directory: oldDir, maxByteSize: 10000)
        let keyA = Self.key("/m/a.flac")
        try await cache.store(Self.makeSource(bytes: 100), for: keyA, identity: Self.sourceIdentity("/m/a.flac"))
        let before = await cache.readySnapshot()

        // Inject the failure: a read-only destination makes copyItem into it fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: newDir.path)

        let moved = try await cache.relocate(to: newDir)

        #expect(moved == false) // move failed
        let hitA = await cache.cachedInstrumental(for: keyA)
        #expect(hitA?.path.hasPrefix(oldDir.path) == true) // OLD dir still serves the lookup
        #expect(hitA.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        let after = await cache.readySnapshot()
        #expect(after.records.sorted { $0.keyHex < $1.keyHex } == before.records.sorted { $0.keyHex < $1.keyHex })

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: newDir.path)
        #expect(try Self.m4aFiles(in: newDir).isEmpty) // no partial copies left behind
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

    var lastSequence: Int? {
        lock.withLock { storage.last?.sequence }
    }
}
