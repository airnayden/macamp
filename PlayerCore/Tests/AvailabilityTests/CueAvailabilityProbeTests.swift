// CueAvailabilityProbeTests — one `stat` per FILE, and not one that outlives the pass.
//
// A CUE disc image is N `track` rows over ONE audio file, so the per-row probe
// loop asked the file system the same question N times for a single yes/no
// answer. `stat(2)` is the part of a reconciliation pass that blocks for seconds
// on a spinning-up drive or a stalled network mount, so N is the figure that
// matters, not the row count.
//
// The memo that collapses it is scoped to ONE ``AvailabilityReconciler/reconcile()``
// call, and the second suite below is the reason that scope is written down: a
// cache that survived a pass would keep reporting a drive as reachable after it
// was unplugged, which is a worse bug than the cost it saves.
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("CueAvailabilityProbeTests")
struct CueAvailabilityProbeTests {
    /// `count` segments of one disc image, all on `filePath`.
    private static func seedSegments(
        _ database: AppDatabase,
        filePath: String,
        count: Int
    ) throws {
        try database.writer.write { db in
            for index in 0 ..< count {
                try db.execute(
                    sql: """
                    INSERT INTO track (filePath, title, cueSheetPath, cueStartFrame, cueEndFrame, availability)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        filePath,
                        "Track \(index + 1)",
                        filePath.replacingOccurrences(of: ".flac", with: ".cue"),
                        Int64(index) * 2250,
                        Int64(index + 1) * 2250,
                        Availability.present.rawValue,
                    ]
                )
            }
        }
    }

    private static func availabilityCounts(_ database: AppDatabase) throws -> [String: Int] {
        try database.writer.read { db in
            var counts: [String: Int] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT availability, COUNT(*) AS n FROM track GROUP BY availability")
            for row in rows {
                counts[row["availability"]] = row["n"]
            }
            return counts
        }
    }

    // MARK: - (b) one probe per distinct path

    @Test("twelve cue rows on one audio file cost exactly one existence probe")
    func twelveCueRowsOnOneFileCostOneProbe() throws {
        let database = try AppDatabase.makeEmpty()
        let fileSystem = FakeFileSystem()
        let path = "/Music/Images/disc.flac"
        fileSystem.addFile(path)
        try Self.seedSegments(database, filePath: path, count: 12)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        fileSystem.resetProbeLog()
        let summary = try reconciler.reconcile()

        #expect(summary.scanned == 12, "every row is still visited — the memo is on the probe, not the walk")
        #expect(fileSystem.fileExistsCalls == [path], "twelve rows, one file, one stat")
    }

    @Test("a 1k-row cue library costs one probe per distinct audio file")
    func aThousandCueRowsCostOneProbePerFile() throws {
        let database = try AppDatabase.makeEmpty()
        let fileSystem = FakeFileSystem()
        let paths = (1 ... 4).map { "/Music/Images/disc\($0).flac" }
        for path in paths {
            fileSystem.addFile(path)
            try Self.seedSegments(database, filePath: path, count: 250)
        }
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        fileSystem.resetProbeLog()
        let summary = try reconciler.reconcile()

        // Pre-memo this loop issued one stat per ROW: 1000. The memo makes the
        // cost a function of the file count, which is what a disc-image library
        // actually has.
        #expect(summary.scanned == 1000)
        #expect(fileSystem.fileExistsCalls.sorted() == paths.sorted())
        #expect(fileSystem.fileExistsCalls.count == 4)
    }

    @Test("an ordinary library of unique paths still probes every row exactly once")
    func uniquePathsStillProbeOncePerRow() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let paths = (1 ... 5).map { "/Music/Library/song\($0).mp3" }
        for path in paths {
            fileSystem.addFile(path)
            try repository.insert(TrackRecord(filePath: path, title: "Song"))
        }
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        fileSystem.resetProbeLog()
        _ = try reconciler.reconcile()

        #expect(
            fileSystem.fileExistsCalls.sorted() == paths.sorted(),
            "the memo never answers for a path it has not seen"
        )
    }

    // MARK: - the memo must not outlive its pass

    @Test("the existence memo does not survive the pass that built it")
    func theExistenceMemoDoesNotSurviveItsPass() throws {
        let database = try AppDatabase.makeEmpty()
        let fileSystem = FakeFileSystem()
        let path = "/Music/Images/ejected.flac"
        fileSystem.addFile(path)
        try Self.seedSegments(database, filePath: path, count: 12)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        _ = try reconciler.reconcile()
        try #expect(Self.availabilityCounts(database) == [Availability.present.rawValue: 12])

        // The file is deleted between passes. A memo that persisted would keep
        // answering "reachable" and the library would never notice.
        fileSystem.removeFile(path)
        fileSystem.resetProbeLog()
        let second = try reconciler.reconcile()

        #expect(fileSystem.fileExistsCalls == [path], "the second pass re-stats rather than trusting the first")
        #expect(second.markedMissing == 12)
        try #expect(Self.availabilityCounts(database) == [Availability.missing.rawValue: 12])
    }

    @Test("an unmount between passes is detected on the very next pass")
    func anUnmountBetweenPassesIsDetected() throws {
        let database = try AppDatabase.makeEmpty()
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Archive")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)
        let path = "/Volumes/Archive/disc.flac"
        fileSystem.addFile(path)
        try Self.seedSegments(database, filePath: path, count: 6)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        _ = try reconciler.reconcile()
        fileSystem.setVolumeMounted(false, root: volumeRoot)
        fileSystem.resetProbeLog()
        let second = try reconciler.reconcile()

        #expect(second.markedExternalOffline == 6)
        #expect(fileSystem.fileExistsCalls == [path])
        // Both memos are per-pass and per-key: one stat, one volume lookup, six rows.
        #expect(fileSystem.volumeCalls == [path])

        fileSystem.setVolumeMounted(true, root: volumeRoot)
        let third = try reconciler.reconcile()
        #expect(third.markedPresent == 6, "a remount is visible to the pass that follows it")
    }
}
