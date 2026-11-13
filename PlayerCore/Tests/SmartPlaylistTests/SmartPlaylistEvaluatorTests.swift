import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Testing

@Suite("SmartPlaylistEvaluatorTests")
struct SmartPlaylistEvaluatorTests {
    @Test("Evaluating materialises the matches as ordered playlistTrack rows")
    func materialisesMembership() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = makeRepository(database)
        try repository.setRules(rockNineties, forPlaylist: SmartPlaylistFixtures.playlistID)

        let evaluation = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let rows = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        #expect(evaluation.trackIds == [1, 4])
        #expect(evaluation.profileId == SmartPlaylistFixtures.profileID)
        #expect(rows.map(\.trackId) == [1, 4])
        #expect(rows.map(\.position) == [0, 1])
    }

    @Test("Evaluating twice produces the same rows, never duplicates")
    func materialisationIsIdempotent() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = makeRepository(database)
        try repository.setRules(rockNineties, forPlaylist: SmartPlaylistFixtures.playlistID)

        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let first = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let second = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        #expect(first.map(\.trackId) == second.map(\.trackId))
        #expect(first.map(\.position) == second.map(\.position))
        #expect(second.count == 2)
    }

    @Test("A rule matching 1000 tracks with limit 50 materialises exactly 50")
    func limitBoundsMaterialisation() throws {
        let database = try makeLargeLibrary(trackCount: 1000)
        let repository = makeRepository(database)
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 50)
        try repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)

        let evaluation = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let rows = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        #expect(evaluation.trackIds.count == 50)
        #expect(rows.count == 50)
        #expect(rows.map(\.position) == Array(0 ..< 50))
    }

    @Test("An absurd limit is capped rather than honoured")
    func limitIsCapped() throws {
        let database = try makeLargeLibrary(trackCount: 1000)
        let repository = makeRepository(database)
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 10000)
        try repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)

        let evaluation = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)

        #expect(evaluation.trackIds.count == SmartPlaylistRules.maximumLimit)
    }

    @Test("A manual reorder persists until the next evaluation rewrites it")
    func manualReorderSurvivesUntilNextEvaluation() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = makeRepository(database)
        try repository.setRules(rockNineties, forPlaylist: SmartPlaylistFixtures.playlistID)
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)

        try PlaylistRepository(database).reorder(
            playlistId: SmartPlaylistFixtures.playlistID,
            orderedTrackIds: [4, 1]
        )
        let reordered = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let reEvaluated = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        #expect(reordered.map(\.trackId) == [4, 1])
        #expect(reEvaluated.map(\.trackId) == [1, 4])
    }

    @Test("A playlist with no rules cannot be evaluated")
    func rejectsPlaylistWithoutRules() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = makeRepository(database)

        #expect(throws: SmartPlaylistError.rulesNotFound(playlistId: SmartPlaylistFixtures.playlistID)) {
            _ = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        }
    }

    @Test("Unreadable rules throw and leave the previous materialisation untouched")
    func failedEvaluationPreservesPriorMaterialisation() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = makeRepository(database)
        try repository.setRules(rockNineties, forPlaylist: SmartPlaylistFixtures.playlistID)
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let before = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE smartPlaylist SET rulesVersion = 99 WHERE playlistId = ?",
                arguments: [SmartPlaylistFixtures.playlistID]
            )
        }
        #expect(throws: SmartPlaylistError.unsupportedRulesVersion(
            found: 99,
            supported: SmartPlaylistRules.currentSchemaVersion
        )) {
            _ = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        }
        let after = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        #expect(before.map(\.trackId) == after.map(\.trackId))
        #expect(after.map(\.trackId) == [1, 4])
    }

    @Test("Malformed rules JSON throws and leaves the previous materialisation untouched")
    func malformedRulesPreservePriorMaterialisation() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = makeRepository(database)
        try repository.setRules(rockNineties, forPlaylist: SmartPlaylistFixtures.playlistID)
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)

        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE smartPlaylist SET rulesJson = ? WHERE playlistId = ?",
                arguments: ["{ not json", SmartPlaylistFixtures.playlistID]
            )
        }
        #expect(throws: SmartPlaylistError.self) {
            _ = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        }
        let after = try SmartPlaylistFixtures.membership(database, playlistId: SmartPlaylistFixtures.playlistID)

        #expect(after.map(\.trackId) == [1, 4])
    }
}

// MARK: - Helpers

private extension SmartPlaylistEvaluatorTests {
    /// The plan's worked example: Rock, 1990–1999, most-played first, capped at 50.
    var rockNineties: SmartPlaylistRules {
        SmartPlaylistRules(
            match: .all,
            predicates: [
                .metadata(.genre(equals: "Rock")),
                .metadata(.year(range: SmartPlaylistRange(lower: 1990, upper: 1999))),
            ],
            sort: SmartPlaylistSort(field: .playCount, direction: .descending),
            limit: 50
        )
    }

    func makeRepository(_ database: AppDatabase) -> SmartPlaylistRepository {
        SmartPlaylistRepository(database, now: FakeClock(SmartPlaylistFixtures.referenceNow).nowProvider)
    }

    /// A library of `trackCount` matching tracks, to prove the `LIMIT` truncates.
    func makeLargeLibrary(trackCount: Int) throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.profileID, name: "Profile A")
            for index in 0 ..< trackCount {
                var track = TrackRecord(
                    id: Int64(index + 1),
                    filePath: "/A/bulk-\(index).flac",
                    availability: .present,
                    genre: "Rock"
                )
                try track.insert(db)
            }
            try SmartPlaylistFixtures.insertPlaylist(
                db,
                id: SmartPlaylistFixtures.playlistID,
                profileId: SmartPlaylistFixtures.profileID
            )
        }
        return database
    }
}
