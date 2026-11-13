// KaraokeReadyStoreTests — proves the in-memory karaoke ready/progress index
// (todo 6): the reorder-guarded, staleness-checked ``ingest`` that projects the
// cache change-seam, plus the monotone progress map. Real temp files exercise the
// default on-disk staleness check; `isFresh: { _ in true }` isolates the reorder /
// equality / eviction logic without touching disk.
import Foundation
import Separation
import Testing
@testable import ViewModels

@MainActor
struct KaraokeReadyStoreTests {
    /// (a) A record whose source still matches on disk is marked ready.
    @Test func ingestWithMatchingStatMarksPathReady() throws {
        let fileURL = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let identity = try SeparationCacheKey.sourceIdentity(for: fileURL)
        let record = ReadyRecord(
            sourcePath: identity.path,
            sourceFileSize: identity.fileSize,
            sourceMTime: identity.mtime,
            keyHex: "a1b2c3"
        )
        let store = KaraokeReadyStore()

        store.ingest(sequence: 1, records: [record])

        #expect(store.isReady(filePath: fileURL.path))
        #expect(store.version == 1)
    }

    /// (b) A record whose file was touched (mtime changed) since it was recorded is
    /// excluded by the default on-disk staleness check.
    @Test func ingestExcludesRecordWhoseFileMTimeChanged() throws {
        let fileURL = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let identity = try SeparationCacheKey.sourceIdentity(for: fileURL)
        let record = ReadyRecord(
            sourcePath: identity.path,
            sourceFileSize: identity.fileSize,
            sourceMTime: identity.mtime,
            keyHex: "a1b2c3"
        )
        // Touch the file so its on-disk mtime no longer matches the record fingerprint.
        let touched = Date(timeIntervalSince1970: identity.mtime + 100)
        try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: fileURL.path)

        let store = KaraokeReadyStore()
        store.ingest(sequence: 1, records: [record])

        #expect(!store.isReady(filePath: fileURL.path))
        #expect(store.readyPaths.isEmpty)
    }

    /// (c) An eviction (a newer snapshot that no longer lists the path) flips isReady
    /// back to false.
    @Test func evictionApplicationFlipsReadyFalse() {
        let store = KaraokeReadyStore()
        let record = ReadyRecord(sourcePath: "/music/a.flac", sourceFileSize: 10, sourceMTime: 1, keyHex: "aa")

        store.ingest(sequence: 1, records: [record], isFresh: { _ in true })
        #expect(store.isReady(filePath: "/music/a.flac"))

        store.ingest(sequence: 2, records: [], isFresh: { _ in true })
        #expect(!store.isReady(filePath: "/music/a.flac"))
        #expect(store.readyPaths.isEmpty)
    }

    /// (d) Progress only ever increases per path and clears on finish.
    @Test func progressOnlyIncreasesPerPathAndClearsOnFinish() {
        let store = KaraokeReadyStore()
        let url = URL(fileURLWithPath: "/music/a.flac")

        store.ingestProgress(url: url, fraction: 0.3)
        #expect(store.progress(filePath: "/music/a.flac") == 0.3)

        store.ingestProgress(url: url, fraction: 0.7)
        #expect(store.progress(filePath: "/music/a.flac") == 0.7)

        // A lower fraction is ignored — a ring never rewinds.
        store.ingestProgress(url: url, fraction: 0.5)
        #expect(store.progress(filePath: "/music/a.flac") == 0.7)

        store.finishRender(url: url, success: true)
        #expect(store.progress(filePath: "/music/a.flac") == nil)
    }

    /// (e) An ingest that yields the same membership does not bump version, even when it
    /// passes the reorder guard (equality-guarded).
    @Test func sameValueIngestDoesNotBumpVersion() {
        let store = KaraokeReadyStore()
        let record = ReadyRecord(sourcePath: "/music/a.flac", sourceFileSize: 10, sourceMTime: 1, keyHex: "aa")

        store.ingest(sequence: 1, records: [record], isFresh: { _ in true })
        #expect(store.version == 1)

        // A newer sequence carrying the SAME membership passes the reorder guard but is
        // equality-guarded, so version does not move.
        store.ingest(sequence: 2, records: [record], isFresh: { _ in true })
        #expect(store.version == 1)
        #expect(store.readyPaths == ["/music/a.flac"])
    }

    /// (f) The reorder guard drops a later application that carries an OLDER sequence
    /// (the async stat-validate + main-hop race), so a fresh set is never wiped.
    @Test func reorderGuardDropsStaleApplication() {
        let store = KaraokeReadyStore()
        let record = ReadyRecord(sourcePath: "/music/a.flac", sourceFileSize: 10, sourceMTime: 1, keyHex: "aa")

        store.ingest(sequence: 2, records: [record], isFresh: { _ in true })
        #expect(store.isReady(filePath: "/music/a.flac"))

        store.ingest(sequence: 1, records: [], isFresh: { _ in true })
        #expect(store.isReady(filePath: "/music/a.flac"))
    }

    /// (g) REGRESSION (bugs 3+5): the FIRST application must apply at the cache's
    /// INITIAL seam sequence (`0`). At launch `readySnapshot()` returns
    /// `(sequence: 0, records)` and only bumps to `1` on the first mutation; a fresh
    /// store whose `lastAppliedSequence` also started at `0` evaluated `0 > 0 == false`
    /// and dropped the entire initial snapshot — the ready list stayed empty until a
    /// NEW render bumped the sequence (bug 5), and every cache-hit resync (still
    /// sequence 0) was re-dropped so a previously-rendered track's badge never
    /// appeared (bug 3).
    @Test func initialIngestAtSequenceZeroApplies() {
        let store = KaraokeReadyStore()
        let record = ReadyRecord(sourcePath: "/music/a.flac", sourceFileSize: 10, sourceMTime: 1, keyHex: "aa")

        store.ingest(sequence: 0, records: [record], isFresh: { _ in true })

        #expect(store.isReady(filePath: "/music/a.flac"))
        #expect(store.version == 1)
    }

    /// (h) End-to-end against the REAL cache: after `remove(sourcePaths:)` deletes one
    /// instrumental, ingesting the next ready snapshot drops exactly that path while the
    /// other stays ready. This is the canonicalization contract in one assertion — the
    /// cache records the symlink-resolved `/private/var/…` spelling, the caller removes
    /// (and queries) with the raw `/var/…` one, and both sides normalize through
    /// `CanonicalSourcePath`.
    @Test func ingestAfterCacheRemovalDropsRemovedPath() async throws {
        let removed = try Self.makeTempFile()
        let kept = try Self.makeTempFile()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaraokeReadyStoreCache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: removed.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: kept.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let cache = try InstrumentalCache(directory: cacheDirectory, maxByteSize: 100_000)
        for url in [removed, kept] {
            let identity = try SeparationCacheKey.sourceIdentity(for: url)
            let key = SeparationCacheKey(identity: identity, modelSHA: "model")
            try await cache.store(url, for: key, identity: identity)
        }
        let store = KaraokeReadyStore()
        let seeded = await cache.readySnapshot()
        store.ingest(sequence: seeded.sequence, records: seeded.records)
        #expect(store.isReady(filePath: removed.path))
        #expect(store.isReady(filePath: kept.path))

        let removedCount = try await cache.remove(sourcePaths: [removed.path])

        #expect(removedCount == 1)
        let after = await cache.readySnapshot()
        store.ingest(sequence: after.sequence, records: after.records)
        #expect(store.isReady(filePath: removed.path) == false)
        #expect(store.isReady(filePath: kept.path))
    }

    /// Writes a small file into a unique temporary directory and returns its URL. The
    /// caller removes the enclosing directory.
    private static func makeTempFile(contents: String = "audio-bytes") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaraokeReadyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("track.flac")
        try Data(contents.utf8).write(to: file)
        return file
    }
}
