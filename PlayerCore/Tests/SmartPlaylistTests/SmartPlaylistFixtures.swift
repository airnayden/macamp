import Foundation
import GRDB
import Persistence

/// The scripted library every smart-playlist suite compiles against.
///
/// Four tracks chosen so each predicate group has one row that matches, one that does
/// not, and — for the profile-state and audio-feature groups — one row that is
/// **absent** from the sparse side table, which is what proves the `LEFT JOIN`
/// defaults and the audio-feature no-op.
enum SmartPlaylistFixtures {
    /// The instant every suite evaluates at, so recency windows land on known days.
    static let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

    static let profileID: Int64 = 2
    static let otherProfileID: Int64 = 3
    static let playlistID: Int64 = 10

    /// | id | genre | year | duration | dateAdded | availability |
    /// |----|-------|------|----------|-----------|--------------|
    /// | 1  | Rock  | 1995 | 200      | 1000      | present      |
    /// | 2  | Rock  | 1985 | 300      | 2000      | present      |
    /// | 3  | Jazz  | 1995 | 400      | 3000      | missing      |
    /// | 4  | rock  | 1999 | 100      | 4000      | present      |
    ///
    /// Track 4's lower-case genre is the case-insensitivity probe.
    static let libraryTracks: [TrackRecord] = [
        TrackRecord(
            id: 1, filePath: "/A/rock90.flac", title: "Rock Ninety",
            artistName: "Alpha", albumTitle: "First",
            duration: 200, availability: .present, dateAdded: 1000, genre: "Rock", year: 1995
        ),
        TrackRecord(
            id: 2, filePath: "/A/rock80.flac", title: "Rock Eighty",
            artistName: "Alpha", albumTitle: "First",
            duration: 300, availability: .present, dateAdded: 2000, genre: "Rock", year: 1985
        ),
        TrackRecord(
            id: 3, filePath: "/A/jazz95.flac", title: "Jazz Ninety",
            artistName: "Beta", albumTitle: "Second",
            duration: 400, availability: .missing, dateAdded: 3000, genre: "Jazz", year: 1995
        ),
        TrackRecord(
            id: 4, filePath: "/A/rock99.flac", title: "Rock Ninety Nine",
            artistName: "Gamma", albumTitle: "Third",
            duration: 100, availability: .present, dateAdded: 4000, genre: "rock", year: 1999
        ),
    ]

    /// A migrated in-memory database seeded with ``libraryTracks``, profile 2 and its
    /// per-track state, play events and audio features. **No** `libraryRoot` rows: with
    /// none configured anywhere every track is ownerless and therefore visible to every
    /// profile, which isolates the predicate under test from visibility scoping.
    static func makeLibrary() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            try insertProfile(db, id: profileID, name: "Profile A")
            for var track in libraryTracks {
                try track.insert(db)
            }
            try seedProfileState(db)
            try seedPlayEvents(db)
            try seedAudioFeatures(db)
            try insertPlaylist(db, id: playlistID, profileId: profileID)
        }
        return database
    }

    static func insertProfile(_ db: Database, id: Int64, name: String) throws {
        var profile = ProfileRecord(id: id, name: name, createdAt: referenceNow)
        try profile.insert(db)
    }

    @discardableResult
    static func insertPlaylist(_ db: Database, id: Int64, profileId: Int64) throws -> Int64 {
        var playlist = PlaylistRecord(id: id, name: "Smart \(id)", isSmartPlaylist: true, profileId: profileId)
        try playlist.insert(db)
        return id
    }

    static func insertRoot(_ db: Database, profileId: Int64, path: String) throws {
        var root = LibraryRootRecord(profileId: profileId, path: path)
        try root.insert(db)
    }

    /// Tracks 1 and 4 have state; 2 and 3 deliberately have **no row**, so the
    /// compiler's `COALESCE` defaults are exercised.
    private static func seedProfileState(_ db: Database) throws {
        try ProfileTrackStateRecord(
            profileId: profileID, trackId: 1, isFavourite: true, playCount: 10, listenedCount: 5
        ).insert(db)
        try ProfileTrackStateRecord(
            profileId: profileID, trackId: 4, isFavourite: false, playCount: 3, listenedCount: 1
        ).insert(db)
    }

    /// Track 1 played yesterday, track 2 played 100 days ago — a 7-day window
    /// separates them.
    private static func seedPlayEvents(_ db: Database) throws {
        let day: TimeInterval = 86400
        for (trackId, daysAgo) in [(Int64(1), 1.0), (Int64(2), 100.0)] {
            var event = PlayEventRecord(
                profileId: profileID,
                trackId: trackId,
                startedAt: referenceNow.timeIntervalSince1970 - daysAgo * day,
                utcOffsetSeconds: 0
            )
            try event.insert(db)
        }
    }

    /// Track 1 is fully analysed, track 4 is analysed but beat-less (`bpm` NULL), and
    /// tracks 2 and 3 were never analysed at all.
    private static func seedAudioFeatures(_ db: Database) throws {
        try TrackAudioFeatureRecord(
            trackId: 1, fileSize: 1, mtime: 0, bpm: 128,
            energy: 0.8, brightness: 0.6, analysisVersion: 1, computedAt: 0
        ).insert(db)
        try TrackAudioFeatureRecord(
            trackId: 4, fileSize: 1, mtime: 0, bpm: nil,
            energy: 0.2, brightness: 0.3, analysisVersion: 1, computedAt: 0
        ).insert(db)
    }
}

// MARK: - Query helpers

extension SmartPlaylistFixtures {
    /// Compiles `rules` and returns the track ids they select, in query order.
    static func matchedIDs(
        _ database: AppDatabase,
        rules: SmartPlaylistRules,
        profileId: Int64 = SmartPlaylistFixtures.profileID,
        now: Date = SmartPlaylistFixtures.referenceNow
    ) throws -> [Int64] {
        try database.writer.read { db in
            try SmartPlaylistCompiler.compile(rules, profileId: profileId, now: now, in: db).request.fetchAll(db)
        }
    }

    /// A rule set of one predicate, `all`-composed, ordered by title.
    static func rules(_ predicate: SmartPlaylistPredicate) -> SmartPlaylistRules {
        SmartPlaylistRules(predicates: [predicate])
    }

    /// The playlist's materialised membership as `(trackId, position)` pairs, in
    /// stored position order.
    static func membership(_ database: AppDatabase, playlistId: Int64) throws -> [PlaylistTrackRecord] {
        try database.writer.read { db in
            try PlaylistTrackRecord
                .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
                .order(PlaylistTrackRecord.Columns.position)
                .fetchAll(db)
        }
    }
}
