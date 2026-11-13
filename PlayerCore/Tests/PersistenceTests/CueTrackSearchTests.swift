// CueTrackSearchTests — a CUE segment is its own FTS5 document.
//
// `trackSearch` is an external-content index over `track`, so its docid IS a
// `track.id`. Before v20 a `filePath` was unique and "one document per file" and
// "one document per row" were the same statement; a disc image makes them
// different, and the whole of full-text search over a cue library rests on the
// second one. The triggers that keep that true were regenerated wholesale by the
// v20 guarded rebuild (todo 29), which is precisely why it is asserted here
// rather than assumed.
import Foundation
import GRDB
import Persistence
import Testing

@Suite("CueTrackSearchTests")
struct CueTrackSearchTests {
    private static let audioPath = "/music/Animals/animals.flac"
    private static let sheetPath = "/music/Animals/animals.cue"
    private static let albumTitle = "Animals"

    /// One suppressed whole-file row plus three segments of the same audio file,
    /// returned with the segment titles in insertion order.
    private static func seedDiscImage(_ database: AppDatabase) throws -> (whole: Int64, segments: [Int64]) {
        let repository = TrackRepository(database)
        let whole = try repository.insert(
            TrackRecord(
                filePath: audioPath,
                title: "animals",
                artistName: "Pink Floyd",
                albumTitle: albumTitle,
                cueSuppressed: true
            )
        )
        let titles = ["Pigs On The Wing", "Dogs", "Sheep"]
        let segments = try titles.enumerated().map { index, title in
            let inserted = try repository.insert(
                TrackRecord(
                    filePath: audioPath,
                    title: title,
                    artistName: "Pink Floyd",
                    albumTitle: albumTitle,
                    cueSheetPath: sheetPath,
                    cueStartFrame: Int64(index) * 2250,
                    cueEndFrame: Int64(index + 1) * 2250
                )
            )
            guard let id = inserted.id else {
                throw CueSearchFixtureError(reason: "segment \(title) received no rowid")
            }
            return id
        }
        guard let wholeID = whole.id else {
            throw CueSearchFixtureError(reason: "whole-file row received no rowid")
        }
        return (wholeID, segments)
    }

    @Test("searching a cue track's title returns exactly that segment's row")
    func searchingACueTitleReturnsExactlyThatRow() throws {
        let database = try AppDatabase.makeEmpty()
        let seeded = try Self.seedDiscImage(database)
        let dogs = seeded.segments[1]

        let matched = try database.writer.read { db in
            try CueTrackFixtures.searchRowIDs(db, matching: "Dogs")
        }

        #expect(matched == [dogs], "one title, one document — the segment's own track row")
        #expect(!matched.contains(seeded.whole), "the whole-file row does not answer for its segments")
    }

    @Test("every segment of one audio file is indexed as its own document")
    func everySegmentIsItsOwnDocument() throws {
        let database = try AppDatabase.makeEmpty()
        let seeded = try Self.seedDiscImage(database)

        let byAlbum = try database.writer.read { db in
            try CueTrackFixtures.searchRowIDs(db, matching: Self.albumTitle)
        }
        let perTitle = try database.writer.read { db in
            try ["Pigs", "Dogs", "Sheep"].map { try CueTrackFixtures.searchRowIDs(db, matching: $0) }
        }

        // Four rows share one filePath; a per-file index would report one docid.
        #expect(byAlbum == ([seeded.whole] + seeded.segments).sorted())
        #expect(perTitle == seeded.segments.map { [$0] })
    }

    @Test("a suppressed whole-file row is indexed but filtered out of searchTracks")
    func suppressionFiltersTheWholeFileRowWithoutDeindexingIt() throws {
        let database = try AppDatabase.makeEmpty()
        let seeded = try Self.seedDiscImage(database)
        let repository = TrackRepository(database)

        let indexed = try database.writer.read { db in
            try CueTrackFixtures.searchRowIDs(db, matching: "animals")
        }
        let surfaced = try repository.searchTracks(query: "animals").compactMap(\.id)

        #expect(indexed.contains(seeded.whole), "suppression is a query filter, never a de-index")
        #expect(!surfaced.contains(seeded.whole), "the retained row must not surface in search results")
    }
}

/// Raised when a fixture could not be built — never by the code under test.
private struct CueSearchFixtureError: Error {
    let reason: String
}
