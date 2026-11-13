// The v20 `(filePath, cueStartFrame)` identity at the Persistence boundary.
//
// Covers the FILEPATH-IDENTITY AUDIT's repository site, plus the reads that MUST
// keep seeing every segment: ``LibraryVisibility`` and the ``AvailabilityReconciler``.
import Foundation
import GRDB
import Persistence
import Testing

struct CueTrackIdentityTests {
    private static let audioPath = "/music/Album/album.flac"
    private static let sheetPath = "/music/Album/album.cue"
    private static let startFrames: [Int64] = [0, 2250, 4500, 6750, 9000]

    /// Five cue segments of one audio file, plus an unrelated whole-file track.
    private func seededSegments(includeWholeFileRow: Bool = false) throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            if includeWholeFileRow {
                var whole = TrackRecord(
                    filePath: Self.audioPath,
                    title: "Whole Rip",
                    fileSize: 1024,
                    mtime: 1,
                    cueSuppressed: true
                )
                try whole.insert(db)
            }
            for (index, frame) in Self.startFrames.enumerated() {
                var segment = TrackRecord(
                    filePath: Self.audioPath,
                    title: "Segment \(index + 1)",
                    sortTitle: "segment \(index + 1)",
                    fileSize: 1024,
                    mtime: 1,
                    cueSheetPath: Self.sheetPath,
                    cueStartFrame: frame,
                    cueEndFrame: index == Self.startFrames.count - 1 ? nil : Self.startFrames[index + 1]
                )
                try segment.insert(db)
            }
        }
        return database
    }

    // MARK: schema identity

    @Test func fiveSegmentsOfOneFileCoexistUnderTheCompositeUniqueKey() throws {
        let database = try seededSegments()

        let rows = try database.writer.read { db in
            try TrackRecord.requestForAllRows(filePath: Self.audioPath).fetchAll(db)
        }

        #expect(rows.count == 5)
        #expect(rows.map(\.cueStartFrame) == Self.startFrames)
        #expect(Set(rows.map(\.filePath)).count == 1)
    }

    @Test func aTrackRecordNamingNoCueColumnStillLandsAWholeFileRow() throws {
        let database = try AppDatabase.makeEmpty()

        try database.writer.write { db in
            var plain = TrackRecord(filePath: "/music/plain.flac")
            try plain.insert(db)
        }

        let row = try #require(
            try database.writer.read { db in
                try TrackRecord.requestForAllRows(filePath: "/music/plain.flac").fetchOne(db)
            }
        )
        #expect(row.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
        #expect(row.cueSheetPath == nil)
        #expect(row.cueEndFrame == nil)
        #expect(row.cueSuppressed == false)
        #expect(row.isCueSegment == false)
    }

    // MARK: FILEPATH-IDENTITY AUDIT — site 1 of 2 in scope (TrackRepository.swift:144)

    @Test func fetchTrackByFilePathPrefersTheWholeFileRowOverAnyCueSegment() throws {
        let database = try seededSegments(includeWholeFileRow: true)

        let resolved = try TrackRepository(database).fetchTrack(filePath: Self.audioPath)

        #expect(resolved?.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
        #expect(resolved?.title == "Whole Rip")
    }

    @Test func fetchTrackByFilePathResolvesDeterministicallyToTheEarliestSegment() throws {
        let database = try seededSegments()

        let resolved = try TrackRepository(database).fetchTrack(filePath: Self.audioPath)

        #expect(resolved?.cueStartFrame == 0)
        #expect(resolved?.title == "Segment 1")
    }

    @Test func fetchTracksByFilePathReturnsEverySegmentInPlayingOrder() throws {
        let database = try seededSegments(includeWholeFileRow: true)

        let rows = try TrackRepository(database).fetchTracks(filePath: Self.audioPath)

        #expect(rows.count == 6)
        #expect(rows.first?.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
        #expect(rows.dropFirst().map(\.cueStartFrame) == Self.startFrames)
    }

    @Test func fetchTrackByIdentityResolvesOneNamedSegment() throws {
        let database = try seededSegments()

        let resolved = try TrackRepository(database)
            .fetchTrack(TrackRecord.Identity(filePath: Self.audioPath, cueStartFrame: 4500))

        #expect(resolved?.title == "Segment 3")
        #expect(resolved?.cueStartFrame == 4500)
    }

    // MARK: reads that MUST NOT filter suppressed rows or collapse segments

    @Test func libraryVisibilityPredicateReturnsEverySegmentForTheOwningProfile() throws {
        let database = try seededSegments()
        try database.writer.write { db in
            var root = LibraryRootRecord(profileId: ProfileRecord.guestID, path: "/music/Album")
            try root.insert(db)
        }

        let visible = try database.writer.read { db in
            let predicate = try LibraryVisibility.predicate(db, profileId: ProfileRecord.guestID)
            return try TrackRecord
                .filter(sql: predicate.sql, arguments: StatementArguments(predicate.arguments))
                .fetchAll(db)
        }

        #expect(visible.count == 5)
        #expect(Set(visible.map(\.cueStartFrame)) == Set(Self.startFrames))
    }

    @Test func availabilityReconcilerMarksEverySegmentOfAVanishedFileMissing() throws {
        let database = try seededSegments()

        let summary = try AvailabilityReconciler(database).reconcile()

        let rows = try database.writer.read { db in
            try TrackRecord.requestForAllRows(filePath: Self.audioPath).fetchAll(db)
        }
        #expect(summary.markedMissing == 5)
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { $0.availability == .missing })
    }

    @Test func availabilityReconcilerStillReachesASuppressedWholeFileRow() throws {
        let database = try seededSegments(includeWholeFileRow: true)

        try AvailabilityReconciler(database).reconcile()

        let suppressed = try database.writer.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.filePath == Self.audioPath)
                .filter(TrackRecord.Columns.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
                .fetchOne(db)
        }
        #expect(suppressed?.cueSuppressed == true)
        #expect(suppressed?.availability == .missing)
    }
}
