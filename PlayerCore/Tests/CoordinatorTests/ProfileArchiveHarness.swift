// ProfileArchiveHarness — the seeded source profile every archive suite exports.
//
// It deliberately differs from `ListeningDigestHarness` in ONE way that matters: the
// seeded library rows carry the SAME `(title, artist, album, duration)` as the event
// and heatmap snapshots, so "every identity matches" is a state a test can actually
// reach. The digest fixture's tracks are named `Song 1` / `Artist 1` on purpose (it
// is proving survivability, not matching); reusing it here would make the roundtrip
// silently exercise the unmatched path.
//
// `now` is pinned to `DigestInstant.now`, so both digests in a roundtrip are measured
// from the same instant and byte-equality means what it says.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

// MARK: - Fixture

/// One local library row the archive is expected to match against.
struct ArchiveTrackSeed {
    var trackId: Int64
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var genre: String = "Rock"
}

enum ArchiveFixture {
    static let sourceProfileName = "Alex"
    static let sourceProfileLastName = "Rivera"
    static let sourceProfileBio = "Listens to too much synthwave."
    static let sourceAvatarId = "waveform-vice"
    static let sourceAvatarImagePath = "/Users/somebody/Library/Application Support/MacAMP/Avatars/alex.png"
    static let sourceLibraryRoot = "/Users/somebody/Music/Collection"
    static let createdAt: Double = 1_700_000_000

    /// The three songs the whole fixture talks about.
    static let songA = ArchiveTrackSeed(
        trackId: 1,
        title: "Song A",
        artist: "Artist A",
        album: "Album A",
        duration: 250
    )
    static let songB = ArchiveTrackSeed(
        trackId: 2,
        title: "Song B",
        artist: "Artist A",
        album: "Album A",
        duration: 300
    )
    static let songC = ArchiveTrackSeed(
        trackId: 3, title: "Song C", artist: "Artist B", album: "Album B", duration: 200, genre: "Jazz"
    )

    static var tracks: [ArchiveTrackSeed] {
        [songA, songB, songC]
    }

    /// Six plays across four windows, three UTC offsets and a DST pair — the same
    /// shape the digest suite uses, but with durations that agree with the library.
    static var events: [DigestEventSeed] {
        [
            event(songA, at: DigestInstant.mondayMorning, offset: 3600, listened: 180, completion: 0.95),
            event(
                songA, at: DigestInstant.tuesdayEvening, offset: -18000,
                listened: 60.5, completion: 0.32, skipped: true
            ),
            event(songB, at: DigestInstant.wednesdayAfternoon, offset: 50400, listened: 240, completion: 1),
            event(songA, at: DigestInstant.dstBefore, offset: -28800, listened: 200.25, completion: 0.9),
            event(songA, at: DigestInstant.dstAfter, offset: -25200, listened: 100, completion: 0.5),
            event(songC, at: DigestInstant.lastYearEvening, offset: 0, listened: 190, completion: 0.99),
        ]
    }

    /// Heatmaps for all three songs, each clearing the replay floor on passes alone,
    /// so `mostReplayed` is non-empty AND non-trivial.
    static var heatmaps: [DigestHeatSeed] {
        [
            heat(songA, buckets: DigestFixture.chorusBuckets, passes: 5),
            heat(songB, buckets: DigestFixture.evenBuckets, passes: 4),
            heat(songC, buckets: DigestFixture.chorusBuckets, passes: 6),
        ]
    }

    static func event(
        _ track: ArchiveTrackSeed,
        at startedAt: Double,
        offset: Int,
        listened: Double,
        completion: Double,
        skipped: Bool = false
    ) -> DigestEventSeed {
        DigestEventSeed(
            trackId: track.trackId,
            artist: track.artist,
            title: track.title,
            album: track.album,
            genre: track.genre,
            startedAt: startedAt,
            utcOffsetSeconds: offset,
            duration: track.duration,
            listened: listened,
            completion: completion,
            skipped: skipped
        )
    }

    static func heat(_ track: ArchiveTrackSeed, buckets: [UInt32], passes: Int) -> DigestHeatSeed {
        DigestHeatSeed(
            trackId: track.trackId,
            artist: track.artist,
            title: track.title,
            album: track.album,
            genre: track.genre,
            duration: track.duration,
            buckets: buckets,
            totalPasses: passes
        )
    }

    /// A settings snapshot that exercises every field kind (enum raw, bool, Int64).
    ///
    /// `themePreset` deliberately holds the RETIRED `"viceCity"` id: the codec must
    /// carry an unknown skin verbatim, and the shell — not this layer — migrates it
    /// (`ThemePresetMigrationTests` in `macampMacTests` owns that assertion, since
    /// `PortableSettingsMapping` and `ThemePreset` both live in the macOS shell).
    static var settings: PortableSettings {
        PortableSettings(
            appearance: "dark",
            replayGainMode: "track",
            gaplessEnabled: true,
            defaultEQPresetName: "Flat",
            defaultVisualizerMode: "bars",
            showVisualizer: false,
            themePreset: "viceCity",
            updateChannel: "stable",
            autoEnrichOnImport: false,
            onlineDataEnabled: true,
            onlineLyricsEnabled: false,
            karaokeEnabled: true,
            karaokeQuality: "standard",
            karaokePruneEnabled: false,
            karaokeCacheCapBytes: 3_221_225_472
        )
    }
}

// MARK: - Seeding

/// Inserts library rows at explicit rowids, so a test can make the target machine's
/// ids deliberately collide with the source's.
func insertArchiveTracks(_ database: AppDatabase, _ seeds: [ArchiveTrackSeed]) throws {
    try database.writer.write { db in
        for seed in seeds {
            var record = TrackRecord(
                id: seed.trackId,
                filePath: "/Music/\(seed.artist)/\(seed.title).flac",
                title: seed.title,
                artistName: seed.artist,
                albumTitle: seed.album,
                duration: seed.duration,
                genre: seed.genre
            )
            try record.insert(db)
        }
    }
}

/// Creates the source profile carrying a PIN, a custom avatar path and a library
/// root — the three things import must refuse to bring across.
func insertArchiveSourceProfile(_ database: AppDatabase) throws -> Int64 {
    let salt = ProfilePIN.makeSalt()
    var profile = ProfileRecord(
        name: ArchiveFixture.sourceProfileName,
        lastName: ArchiveFixture.sourceProfileLastName,
        bio: ArchiveFixture.sourceProfileBio,
        avatarId: ArchiveFixture.sourceAvatarId,
        avatarImagePath: ArchiveFixture.sourceAvatarImagePath,
        pinHash: ProfilePIN.hash(pin: "1234", salt: salt),
        pinSalt: salt.base64EncodedString(),
        createdAt: Date(timeIntervalSince1970: ArchiveFixture.createdAt)
    )
    return try database.writer.write { db -> Int64 in
        try profile.insert(db)
        let id = profile.id ?? 0
        var root = LibraryRootRecord(profileId: id, path: ArchiveFixture.sourceLibraryRoot)
        try root.insert(db)
        return id
    }
}

func insertArchiveTrackStates(_ database: AppDatabase, profileId: Int64, seeds: [ArchiveTrackSeed]) throws {
    try database.writer.write { db in
        for (index, seed) in seeds.enumerated() {
            try ProfileTrackStateRecord(
                profileId: profileId,
                trackId: seed.trackId,
                isFavourite: index == 0,
                playCount: 10 + index,
                listenedCount: 4 + index,
                customPosition: index
            ).insert(db)
        }
    }
}

/// The complete source: library rows, the profile, six plays, one rollup, three
/// heatmaps and three counter rows.
@discardableResult
func seedArchiveFixture(_ database: AppDatabase) throws -> Int64 {
    try insertArchiveTracks(database, ArchiveFixture.tracks)
    let profileId = try insertArchiveSourceProfile(database)
    for seed in ArchiveFixture.events {
        try insertDigestEvent(database, seed, profileId: profileId)
    }
    try insertDigestRollup(database, profileId: profileId)
    for seed in ArchiveFixture.heatmaps {
        try insertDigestHeat(database, seed, profileId: profileId)
    }
    try insertArchiveTrackStates(database, profileId: profileId, seeds: ArchiveFixture.tracks)
    return profileId
}

// MARK: - Convenience

func makeArchiveExporter(_ database: AppDatabase, pageSize: Int = 500) -> ProfileArchiveExporter {
    ProfileArchiveExporter(database, pageSize: pageSize)
}

func makeArchiveImporter(_ database: AppDatabase, pageSize: Int = 500) -> ProfileArchiveImporter {
    ProfileArchiveImporter(database, pageSize: pageSize)
}

/// The profile's digest as canonical JSON bytes, measured from the pinned instant.
func archiveDigestJSON(_ database: AppDatabase, profileId: Int64) async throws -> Data {
    let digest = try await makeDigestBuilder(database).buildDigest(profileId: profileId)
    return try digest.encodedJSON()
}

func fetchProfile(_ database: AppDatabase, id: Int64) throws -> ProfileRecord? {
    try database.writer.read { db in try ProfileRecord.fetchOne(db, key: id) }
}

/// Non-async on purpose: inside an `async` test the async GRDB overload wins and
/// every read would need an `await` that reads like a mistake.
func countProfiles(_ database: AppDatabase) throws -> Int {
    try database.writer.read { db in try ProfileRecord.fetchCount(db) }
}

func fetchPlayEvents(_ database: AppDatabase, profileId: Int64, title: String) throws -> [PlayEventRecord] {
    try database.writer.read { db in
        try PlayEventRecord
            .filter(PlayEventRecord.Columns.profileId == profileId)
            .filter(PlayEventRecord.Columns.title == title)
            .order(PlayEventRecord.Columns.id)
            .fetchAll(db)
    }
}

func fetchSegmentHeatTrackIds(_ database: AppDatabase, profileId: Int64) throws -> [Int64] {
    try database.writer.read { db in
        try Int64.fetchAll(
            db,
            sql: "SELECT trackId FROM playSegmentHeat WHERE profileId = ? ORDER BY trackId",
            arguments: [profileId]
        )
    }
}

func countRows(_ database: AppDatabase, table: String, profileId: Int64) throws -> Int {
    try database.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE profileId = ?", arguments: [profileId]) ?? 0
    }
}

/// SQLite's own referential-integrity audit. Empty means zero dangling foreign keys.
func foreignKeyViolationCount(_ database: AppDatabase) throws -> Int {
    try database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
    }
}
