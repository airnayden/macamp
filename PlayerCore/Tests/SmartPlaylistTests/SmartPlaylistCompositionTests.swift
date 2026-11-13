import Foundation
import GRDB
import Persistence
import Testing

@Suite("SmartPlaylistCompositionTests")
struct SmartPlaylistCompositionTests {
    @Test("`all` intersects the predicates")
    func composesAllMode() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(
            match: .all,
            predicates: [
                .metadata(.genre(equals: "Rock")),
                .metadata(.year(range: SmartPlaylistRange(lower: 1990, upper: 1999))),
            ]
        )

        let ids = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)

        #expect(ids.sorted() == [1, 4])
    }

    @Test("`any` unions the predicates")
    func composesAnyMode() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(
            match: .any,
            predicates: [
                .metadata(.genre(equals: "Jazz")),
                .profileStat(.isFavourite(equals: true)),
            ]
        )

        let ids = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)

        #expect(ids.sorted() == [1, 3])
    }

    @Test("An empty rule set is the whole visible library under either mode")
    func emptyPredicatesMatchEverything() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let allMode = try SmartPlaylistFixtures.matchedIDs(database, rules: SmartPlaylistRules(match: .all))
        let anyMode = try SmartPlaylistFixtures.matchedIDs(database, rules: SmartPlaylistRules(match: .any))

        #expect(allMode.sorted() == [1, 2, 3, 4])
        #expect(anyMode.sorted() == [1, 2, 3, 4])
    }

    @Test("Sorting orders by the requested field, then by id to break ties")
    func ordersBySortField() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(sort: SmartPlaylistSort(field: .playCount, direction: .descending))

        let ids = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)

        #expect(ids == [1, 4, 2, 3])
    }

    @Test("Sorting ascending reverses the ranking without disturbing the id tie-break")
    func ordersAscending() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(sort: SmartPlaylistSort(field: .dateAdded, direction: .ascending))

        let ids = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)

        #expect(ids == [1, 2, 3, 4])
    }

    @Test("Every compiled query carries a LIMIT and binds every value")
    func alwaysEmitsBoundLimit() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 3)

        let query = try database.writer.read { db in
            try SmartPlaylistCompiler.compile(
                rules,
                profileId: SmartPlaylistFixtures.profileID,
                now: SmartPlaylistFixtures.referenceNow,
                in: db
            )
        }

        #expect(query.sql.contains("LIMIT ?"))
        #expect(!query.sql.contains("Rock"))
        #expect(query.arguments.count == query.sql.count(where: { $0 == "?" }))
    }

    @Test("The limit truncates the result to exactly the requested count")
    func limitTruncatesResults() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(
            sort: SmartPlaylistSort(field: .dateAdded, direction: .ascending),
            limit: 2
        )

        let ids = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)

        #expect(ids == [1, 2])
    }

    @Test("A profile only sees tracks beneath its own roots, or beneath none at all")
    func appliesLibraryVisibility() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        try database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.otherProfileID, name: "Profile B")
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.profileID, path: "/A")
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.otherProfileID, path: "/B")
            var loose = TrackRecord(id: 99, filePath: "/elsewhere/loose.flac", genre: "Rock")
            try loose.insert(db)
        }

        let mine = try SmartPlaylistFixtures.matchedIDs(database, rules: SmartPlaylistRules())
        let theirs = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistRules(),
            profileId: SmartPlaylistFixtures.otherProfileID
        )

        #expect(mine.sorted() == [1, 2, 3, 4, 99])
        #expect(theirs.sorted() == [99])
    }
}
