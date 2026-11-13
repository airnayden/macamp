import GRDB
import Persistence
import Testing

@Suite("ProfilePlaybackStateRepositoryTests", .serialized)
struct ProfilePlaybackStateRepositoryTests {
    @Test("v14 creates profilePlaybackState on an empty database")
    func migrationAppliesToEmptyDatabase() throws {
        let appDB = try AppDatabase.makeEmpty()

        try appDB.writer.read { db in
            try #expect(db.tableExists("profilePlaybackState"))
            let columns = try db.columns(in: "profilePlaybackState")
            #expect(columns.map(\.name) == ["profileId", "snapshotJson", "sourceJson", "savedAt"])
            #expect(columns.first { $0.name == "snapshotJson" }?.isNotNull == true)
            #expect(columns.first { $0.name == "sourceJson" }?.isNotNull == false)
            #expect(columns.first { $0.name == "savedAt" }?.isNotNull == true)
        }
    }

    @Test("v14 migrates a v13 database without losing its existing profile")
    func migrationAppliesToSeededV13Database() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v13")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO profile (id, name, createdAt) VALUES (?, ?, datetime('now'))",
                arguments: [2, "Existing"]
            )
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("profilePlaybackState"))
            let profileName = try String.fetchOne(db, sql: "SELECT name FROM profile WHERE id = 2")
            #expect(profileName == "Existing")
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
        }
    }

    @Test("upsert and fetch round-trip opaque snapshot and source JSON")
    func upsertFetchRoundTrip() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = ProfilePlaybackStateRepository(appDB)

        try await repository.upsert(
            for: ProfileRecord.guestID,
            snapshotJson: #"{"position":12.5}"#,
            sourceJson: nil,
            savedAt: 1000
        )
        try await repository.upsert(
            for: ProfileRecord.guestID,
            snapshotJson: #"{"position":42.0}"#,
            sourceJson: #"{"kind":"playlist","id":7}"#,
            savedAt: 2000.5
        )

        let stored = try await repository.fetch(for: ProfileRecord.guestID)
        let fetched = try #require(stored)
        #expect(fetched == ProfilePlaybackStateRecord(
            profileId: ProfileRecord.guestID,
            snapshotJson: #"{"position":42.0}"#,
            sourceJson: #"{"kind":"playlist","id":7}"#,
            savedAt: 2000.5
        ))

        try await repository.delete(for: ProfileRecord.guestID)
        #expect(try await repository.fetch(for: ProfileRecord.guestID) == nil)
    }

    @Test("deleting a profile cascades to profilePlaybackState")
    func profileDeleteCascades() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let profileRepository = ProfileRepository(appDB)
        let stateRepository = ProfilePlaybackStateRepository(appDB)
        let profile = try profileRepository.create(ProfileRecord(name: "Ada"))
        let profileID = try #require(profile.id)
        try await stateRepository.upsert(
            for: profileID,
            snapshotJson: "{}",
            sourceJson: nil,
            savedAt: 1
        )

        try profileRepository.delete(id: profileID)

        #expect(try await stateRepository.fetch(for: profileID) == nil)
    }

    @Test("upsert for a nonexistent profile fails the foreign key")
    func nonexistentProfileFailsForeignKey() async throws {
        let repository = try ProfilePlaybackStateRepository(AppDatabase.makeEmpty())

        await #expect(throws: DatabaseError.self) {
            try await repository.upsert(
                for: 9999,
                snapshotJson: "{}",
                sourceJson: nil,
                savedAt: 1
            )
        }
    }
}
