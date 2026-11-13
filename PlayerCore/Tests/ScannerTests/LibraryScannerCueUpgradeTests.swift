// The UPGRADE path: a library scanned BEFORE its `.cue` appeared.
//
// The whole-file row is RETAINED and flagged `cueSuppressed = 1`, never deleted.
// Deleting it would cascade `playlistTrack` / `profileTrackState` /
// `folderTrackOrder` and orphan the bare-`trackId` `playEvent` rows. Each guarantee
// gets its own named test so a regression names the exact thing it destroyed.
//
// Every database read lives in a NON-async helper: GRDB publishes async overloads of
// `read`/`write` and of the repository pages, and calling them from an async test
// body would silently resolve to those instead.
import Foundation
import GRDB
import Metadata
import Persistence
@testable import Services
import Testing

@Suite(.serialized)
struct LibraryScannerCueUpgradeTests {
    /// Everything the upgrade scenario needs to make its assertions.
    private struct Upgraded {
        let database: AppDatabase
        let directory: URL
        let audio: URL
        let wholeFileId: Int64
        let playlistId: Int64
        let profileId: Int64
    }

    // MARK: scenario

    /// Scans the bare FLAC, gives the resulting row a favourite, a playlist
    /// membership and a play event, then drops in the `.cue` and re-scans.
    private func makeUpgraded() async throws -> Upgraded {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        let audio = try CueScanFixtures.writeAudio(in: dir)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())
        _ = await scanner.scan(.directory(dir))

        let seeded = try Self.seedUserData(database, audioPath: audio.path)

        try CueScanFixtures.writeSheet(in: dir)
        _ = await scanner.scan(.directory(dir))

        return Upgraded(
            database: database,
            directory: dir,
            audio: audio,
            wholeFileId: seeded.wholeFileId,
            playlistId: seeded.playlistId,
            profileId: ProfileRecord.guestID
        )
    }

    private static func seedUserData(
        _ database: AppDatabase,
        audioPath: String
    ) throws -> (wholeFileId: Int64, playlistId: Int64) {
        let existing = try database.writer.read { db in
            try TrackRecord.requestForAllRows(filePath: audioPath).fetchOne(db)
        }
        let wholeFileId = try #require(existing?.id)
        let playlists = PlaylistRepository(database)
        let playlist = try playlists.create(named: "Kept", profileId: ProfileRecord.guestID)
        let playlistId = try #require(playlist.id)
        _ = try playlists.addTrack(trackId: wholeFileId, toPlaylist: playlistId)
        try database.writer.write { db in
            var state = ProfileTrackStateRecord(
                profileId: ProfileRecord.guestID,
                trackId: wholeFileId,
                isFavourite: true,
                playCount: 3,
                listenedCount: 2,
                customPosition: nil
            )
            try state.insert(db)
            var event = PlayEventRecord(
                profileId: ProfileRecord.guestID,
                trackId: wholeFileId,
                artistName: "The Beatles",
                title: "Come Together",
                startedAt: 1_700_000_000,
                utcOffsetSeconds: 0,
                secondsListened: 120
            )
            try event.insert(db)
        }
        return (wholeFileId, playlistId)
    }

    // MARK: non-async reads

    private static func row(_ database: AppDatabase, id: Int64) throws -> TrackRecord? {
        try database.writer.read { db in try TrackRecord.fetchOne(db, key: id) }
    }

    private static func memberships(_ database: AppDatabase, trackId: Int64) throws -> [PlaylistTrackRecord] {
        try database.writer.read { db in
            try PlaylistTrackRecord.filter(PlaylistTrackRecord.Columns.trackId == trackId).fetchAll(db)
        }
    }

    private static func events(_ database: AppDatabase, trackId: Int64) throws -> [PlayEventRecord] {
        try database.writer.read { db in
            try PlayEventRecord.filter(PlayEventRecord.Columns.trackId == trackId).fetchAll(db)
        }
    }

    private static func playlistItems(_ database: AppDatabase, playlistId: Int64) throws -> [PlaylistTrackItem] {
        try PlaylistRepository(database).playlistTracksPage(playlistId: playlistId).items
    }

    private static func browseListing(_ database: AppDatabase, profileId: Int64) throws -> [TrackRecord] {
        try TrackRepository(database).tracksPage(profileId: profileId).items
    }

    // MARK: assertion 1 — the row survives, hidden

    @Test func upgradeRetainsTheWholeFileRowAsSuppressedRatherThanDeletingIt() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let stored = try Self.row(scenario.database, id: scenario.wholeFileId)

        let row = try #require(stored)
        #expect(row.cueSuppressed)
        #expect(row.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
        #expect(row.cueSheetPath == nil)
    }

    @Test func upgradeAddsTheFiveCueSegmentsAlongsideTheSuppressedRow() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let rows = try CueScanFixtures.storedSegments(scenario.database, audio: scenario.audio)

        #expect(rows.count == 6)
        #expect(rows.filter(\.isCueSegment).map(\.cueStartFrame) == CueScanFixtures.startFrames)
        #expect(rows.count(where: \.cueSuppressed) == 1)
    }

    // MARK: assertion 2 — playlist membership intact

    @Test func upgradeRetainsThePlaylistMembershipOfTheSuppressedRow() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let memberships = try Self.memberships(scenario.database, trackId: scenario.wholeFileId)

        #expect(memberships.count == 1)
        #expect(memberships.first?.playlistId == scenario.playlistId)
    }

    // MARK: assertion 3 — favourite intact

    @Test func upgradeRetainsTheFavouriteOfTheSuppressedRow() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let favourites = try TrackRepository(scenario.database)
            .favouriteTrackIDs(profileId: scenario.profileId)

        #expect(favourites.contains(scenario.wholeFileId))
    }

    // MARK: assertion 4 — listening history intact

    @Test func upgradeRetainsThePlayEventsOfTheSuppressedRow() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let events = try Self.events(scenario.database, trackId: scenario.wholeFileId)

        #expect(events.count == 1)
        #expect(events.first?.secondsListened == 120)
    }

    // MARK: assertion 5 — view-level proof, not just row survival

    @Test func suppressedRowStillReadsBackFromItsPlaylistAndResolvesToPlayableAudio() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let items = try Self.playlistItems(scenario.database, playlistId: scenario.playlistId)

        let item = try #require(items.first { $0.track.id == scenario.wholeFileId })
        #expect(items.count == 1)
        #expect(item.track.cueSuppressed)
        #expect(item.track.availability == .present)
        #expect(FileManager.default.fileExists(atPath: item.track.filePath))
    }

    // MARK: the two surfaces that DO hide it

    @Test func browseListingReturnsOnlyTheFiveCueRowsAfterUpgrade() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }

        let items = try Self.browseListing(scenario.database, profileId: scenario.profileId)
        let segmentCount = items.filter(\.isCueSegment).count

        #expect(items.count == 5)
        #expect(segmentCount == 5)
        #expect(items.contains { $0.id == scenario.wholeFileId } == false)
    }

    @Test func fullTextSearchStopsReturningTheSuppressedRowAfterUpgrade() async throws {
        let scenario = try await makeUpgraded()
        defer { try? FileManager.default.removeItem(at: scenario.directory) }
        let repository = TrackRepository(scenario.database)

        let suppressedHits = try repository.searchTracks(profileId: scenario.profileId, query: "Come Together")
        let segmentHits = try repository.searchTracks(profileId: scenario.profileId, query: "Three")

        #expect(suppressedHits.isEmpty)
        #expect(segmentHits.count == 1)
    }
}
