import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Testing

@Suite("SmartPlaylistRepositoryTests")
struct SmartPlaylistRepositoryTests {
    @Test("Rules round-trip through the smartPlaylist row")
    func storesAndReadsRules() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 50)

        let record = try repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)
        let readBack = try repository.rules(forPlaylist: SmartPlaylistFixtures.playlistID)

        #expect(record.rulesVersion == SmartPlaylistRules.currentSchemaVersion)
        #expect(record.lastEvaluatedAt == nil)
        #expect(readBack == rules)
    }

    @Test("A playlist with no rules reads as nil rather than throwing")
    func missingRulesReadAsNil() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)

        let readBack = try repository.rules(forPlaylist: SmartPlaylistFixtures.playlistID)

        #expect(readBack == nil)
    }

    @Test("Writing rules replaces the single row instead of adding another")
    func setRulesUpserts() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)
        try repository.setRules(
            SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))]),
            forPlaylist: SmartPlaylistFixtures.playlistID
        )

        let updated = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Jazz"))])
        try repository.setRules(updated, forPlaylist: SmartPlaylistFixtures.playlistID)
        let rowCount = try database.writer.read { db in try SmartPlaylistRecord.fetchCount(db) }

        #expect(rowCount == 1)
        #expect(try repository.rules(forPlaylist: SmartPlaylistFixtures.playlistID) == updated)
    }

    @Test("Rewriting the rules makes the playlist stale again")
    func setRulesResetsEvaluationStamp() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))])
        try repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)

        let freshBefore = try repository.isStale(playlistId: SmartPlaylistFixtures.playlistID, ttl: 3600)
        try repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)
        let staleAfter = try repository.isStale(playlistId: SmartPlaylistFixtures.playlistID, ttl: 3600)

        #expect(freshBefore == false)
        #expect(staleAfter == true)
    }

    @Test("Staleness compares lastEvaluatedAt against the injected clock")
    func staleAfterTTL() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let clock = FakeClock(SmartPlaylistFixtures.referenceNow)
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)
        try repository.setRules(
            SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))]),
            forPlaylist: SmartPlaylistFixtures.playlistID
        )

        let staleBeforeFirstEvaluation = try repository.isStale(
            playlistId: SmartPlaylistFixtures.playlistID,
            ttl: 3600
        )
        try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let freshImmediately = try repository.isStale(playlistId: SmartPlaylistFixtures.playlistID, ttl: 3600)
        clock.advance(by: 3600)
        let staleAtTTL = try repository.isStale(playlistId: SmartPlaylistFixtures.playlistID, ttl: 3600)

        #expect(staleBeforeFirstEvaluation == true)
        #expect(freshImmediately == false)
        #expect(staleAtTTL == true)
    }

    @Test("Staleness is not a question an ordinary playlist can answer")
    func stalenessRequiresRules() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)

        #expect(throws: SmartPlaylistError.rulesNotFound(playlistId: SmartPlaylistFixtures.playlistID)) {
            _ = try repository.isStale(playlistId: SmartPlaylistFixtures.playlistID, ttl: 3600)
        }
    }

    @Test("Evaluation stamps lastEvaluatedAt from the injected clock")
    func evaluationStampsClock() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)
        try repository.setRules(
            SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))]),
            forPlaylist: SmartPlaylistFixtures.playlistID
        )

        let evaluation = try repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let stored = try database.writer.read { db in
            try SmartPlaylistRecord
                .filter(SmartPlaylistRecord.Columns.playlistId == SmartPlaylistFixtures.playlistID)
                .fetchOne(db)?.lastEvaluatedAt
        }

        #expect(evaluation.evaluatedAt == SmartPlaylistFixtures.referenceNow.timeIntervalSince1970)
        #expect(stored == evaluation.evaluatedAt)
    }

    @Test("The async twins agree with the synchronous ones")
    func asyncOverloadsMatch() async throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let repository = SmartPlaylistRepository(database, now: clock.nowProvider)
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 50)

        try await repository.setRules(rules, forPlaylist: SmartPlaylistFixtures.playlistID)
        let readBack = try await repository.rules(forPlaylist: SmartPlaylistFixtures.playlistID)
        let evaluation = try await repository.evaluate(playlistId: SmartPlaylistFixtures.playlistID)
        let stale = try await repository.isStale(playlistId: SmartPlaylistFixtures.playlistID, ttl: 3600)

        #expect(readBack == rules)
        #expect(evaluation.trackIds.sorted() == [1, 2, 4])
        #expect(stale == false)
    }

    private var clock: FakeClock {
        FakeClock(SmartPlaylistFixtures.referenceNow)
    }
}
