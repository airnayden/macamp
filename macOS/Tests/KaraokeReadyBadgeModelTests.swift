import Foundation
@testable import MacAMP
import Persistence
import Separation
import Testing
import ViewModels

@MainActor
@Suite("KaraokeReadyBadgeModelTests", .serialized)
struct KaraokeReadyBadgeModelTests {
    @Test("resolved count ignores ready cache paths absent from the library")
    func resolvedCountMatchesLibrarySubset() async throws {
        let database = try AppDatabase.makeEmpty()
        let store = readyStore(paths: ["/Music/a.flac", "/Music/b.flac", "/Music/c.flac"])
        let model = KaraokeReadyBadgeModel(
            readyStore: store,
            repository: TrackRepository(database)
        )

        await model.recompute(profileId: ProfileRecord.guestID)
        #expect(model.resolvedCount == 0)

        try seedTrack(database, path: "/Music/a.flac", title: "Alpha")
        try seedTrack(database, path: "/Music/b.flac", title: "Bravo")
        await model.recompute(profileId: ProfileRecord.guestID)

        #expect(store.readyPaths.count == 3)
        #expect(model.resolvedCount == 2)
    }

    @Test("recompute switches the resolved count to the requested profile")
    func recomputeUsesActiveProfile() async throws {
        let database = try AppDatabase.makeEmpty()
        let profiles = ProfileRepository(database)
        let first = try makeProfile(profiles, name: "First")
        let second = try makeProfile(profiles, name: "Second")
        let roots = LibraryRootRepository(database)
        try roots.addRoot(profileId: first, path: "/Music/First")
        try roots.addRoot(profileId: second, path: "/Music/Second")
        let paths = [
            "/Music/First/a.flac",
            "/Music/First/b.flac",
            "/Music/Second/c.flac",
        ]
        try seedTrack(database, path: paths[0], title: "Alpha")
        try seedTrack(database, path: paths[1], title: "Bravo")
        try seedTrack(database, path: paths[2], title: "Charlie")
        let model = KaraokeReadyBadgeModel(
            readyStore: readyStore(paths: paths),
            repository: TrackRepository(database)
        )

        await model.recompute(profileId: first)
        #expect(model.resolvedCount == 2)
        await model.recompute(profileId: second)
        #expect(model.resolvedCount == 1)
    }

    @Test("ready paths preserve the database's private-var filesystem alias")
    func privateVarAliasMatchesLibraryPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Alias.mp3")
        try Data([0]).write(to: source)
        let databasePath = source.path.hasPrefix("/var/") ? "/private\(source.path)" : source.path

        let database = try AppDatabase.makeEmpty()
        try seedTrack(database, path: databasePath, title: "Alias")
        let model = KaraokeReadyBadgeModel(
            readyStore: readyStore(paths: [databasePath]),
            repository: TrackRepository(database)
        )

        await model.recompute(profileId: ProfileRecord.guestID)

        #expect(model.resolvedCount == 1)
    }

    @Test("task key changes for readiness, library revision, and active profile")
    func taskKeyTracksEveryResolutionInput() {
        let initial = KaraokeReadyBadgeLoadKey(readyVersion: 1, libraryRevision: 2, profileId: 3)

        #expect(initial != KaraokeReadyBadgeLoadKey(readyVersion: 2, libraryRevision: 2, profileId: 3))
        #expect(initial != KaraokeReadyBadgeLoadKey(readyVersion: 1, libraryRevision: 3, profileId: 3))
        #expect(initial != KaraokeReadyBadgeLoadKey(readyVersion: 1, libraryRevision: 2, profileId: 4))
    }

    @Test("ready list task key changes when the library revision changes")
    func readyListTaskKeyTracksLibraryRevision() {
        let initial = KaraokeReadyLoadKey(profileId: 3, version: 1, libraryRevision: 2)

        #expect(initial != KaraokeReadyLoadKey(profileId: 3, version: 1, libraryRevision: 3))
    }

    private func readyStore(paths: [String]) -> KaraokeReadyStore {
        let store = KaraokeReadyStore()
        let records = paths.enumerated().map { index, path in
            ReadyRecord(
                sourcePath: path,
                sourceFileSize: 0,
                sourceMTime: 0,
                keyHex: String(index)
            )
        }
        store.ingest(sequence: 0, records: records, isFresh: { _ in true })
        return store
    }

    private func seedTrack(_ database: AppDatabase, path: String, title: String) throws {
        _ = try TrackRepository(database).insert(TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title.lowercased()
        ))
    }

    private func makeProfile(_ repository: ProfileRepository, name: String) throws -> Int64 {
        let profile = try repository.create(ProfileRecord(name: name))
        return try #require(profile.id)
    }
}
