import Foundation
import GRDB
import Persistence
import Testing

/// `previewTrackIds(matching:profileId:)` is the read-only half of `evaluate`: same
/// compiler, same visibility scoping, same `LIMIT` — and NO membership rewrite.
///
/// It exists so the assistant can ask "what would these rules select?" without the
/// question having a side effect, which is the whole propose-and-preview contract.
struct SmartPlaylistPreviewTests {
    @Test func previewReturnsTheSameIdsInTheSameOrderAsAnEvaluation() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: { SmartPlaylistFixtures.referenceNow })
        let rules = SmartPlaylistRules(
            match: .all,
            predicates: [.metadata(.genre(equals: "Rock"))],
            sort: SmartPlaylistSort(field: .title, direction: .ascending)
        )
        try repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)

        let previewed = try repository.previewTrackIds(
            matching: rules,
            profileId: SmartPlaylistFixtures.profileID
        )
        let evaluated = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)

        #expect(!previewed.isEmpty)
        #expect(previewed == evaluated.trackIds)
    }

    @Test func previewWritesNoMembershipRows() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: { SmartPlaylistFixtures.referenceNow })
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))])

        _ = try repository.previewTrackIds(
            matching: rules,
            profileId: SmartPlaylistFixtures.profileID
        )

        let membershipCount = try database.writer.read { db in
            try PlaylistTrackRecord.fetchCount(db)
        }
        #expect(membershipCount == 0)
    }

    /// Rules that were never stored still preview — an assistant request is not a
    /// playlist until the listener applies it, so there is no row to read them from.
    @Test func previewNeedsNoStoredRulesAndStoresNone() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: { SmartPlaylistFixtures.referenceNow })

        let previewed = try repository.previewTrackIds(
            matching: SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Jazz"))]),
            profileId: SmartPlaylistFixtures.profileID
        )

        #expect(previewed == [3])
        let storedRules = try repository.rules(forPlaylist: SmartPlaylistFixtures.playlistID)
        #expect(storedRules == nil)
    }

    @Test func previewHonoursTheRuleSetsLimit() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: { SmartPlaylistFixtures.referenceNow })

        let previewed = try repository.previewTrackIds(
            matching: SmartPlaylistRules(limit: 1),
            profileId: SmartPlaylistFixtures.profileID
        )

        #expect(previewed.count == 1)
    }

    @Test func previewIsScopedToTheProfileItWasAskedAbout() async throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        try await database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(
                db,
                id: SmartPlaylistFixtures.otherProfileID,
                name: "Profile B"
            )
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.profileID, path: "/A")
            try SmartPlaylistFixtures.insertRoot(
                db,
                profileId: SmartPlaylistFixtures.otherProfileID,
                path: "/B"
            )
        }
        let repository = SmartPlaylistRepository(database, now: { SmartPlaylistFixtures.referenceNow })
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))])

        let owner = try await repository.previewTrackIds(
            matching: rules,
            profileId: SmartPlaylistFixtures.profileID
        )
        let rival = try await repository.previewTrackIds(
            matching: rules,
            profileId: SmartPlaylistFixtures.otherProfileID
        )

        #expect(!owner.isEmpty)
        #expect(rival.isEmpty)
    }
}
