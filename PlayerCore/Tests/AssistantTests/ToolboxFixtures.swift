import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services

/// The scripted library every `LibraryToolbox` suite runs against.
///
/// Shaped so each tool has a row that matches, a row that does not, and a row that
/// is ABSENT from a sparse side table — the same three-way coverage
/// `SmartPlaylistFixtures` uses, extended with the two things the tool layer adds:
/// a track owned by a DIFFERENT profile (visibility scoping must hide it) and a
/// block of filler rows large enough to force truncation.
enum ToolboxFixtures {
    /// The instant every suite evaluates at, so recency windows land on known days.
    static let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

    static let profileID: Int64 = 2
    static let otherProfileID: Int64 = 3
    static let playlistID: Int64 = 10
    static let otherPlaylistID: Int64 = 11

    /// Filler rows seeded so a capped render has something to drop. Comfortably
    /// above every profile's `rowLimit`.
    static let fillerCount = 30

    /// The path prefix EVERY fixture file lives under. The privacy sweep asserts
    /// this string never appears in a rendered result, so it must be distinctive.
    static let pathPrefix = "/Fixtures"

    /// | id | title | artist | album | genre | year | availability |
    /// |----|-------|--------|-------|-------|------|--------------|
    /// | 1 | Aurora Drift  | Nova Field     | Northern Lights | Ambient    | 2001 | present |
    /// | 2 | Crimson Pulse | Nova Field     | Northern Lights | Electronic | 2014 | present |
    /// | 3 | Ember Waltz   | Paper Lanterns | Slow Burn       | Jazz       | 1995 | present |
    /// | 4 | Frostbite     | Glass Harbour  | Winterlong      | Electronic | 2020 | missing |
    /// | 5 | Golden Hour   | Paper Lanterns | Slow Burn       | (none)     | 2008 | present |
    /// | 6 | Hidden Track  | Other Owner    | Elsewhere       | Rock       | 1999 | present |
    ///
    /// Track 4 is `missing` (never sampled), track 5 is untagged (the "(no genre)"
    /// bucket), and track 6 lives under the OTHER profile's library root.
    static let libraryTracks: [TrackRecord] = [
        track(1, "Aurora Drift", "Nova Field", "Northern Lights", "Ambient", 2001, 245, .present, "Library/aurora"),
        track(
            2,
            "Crimson Pulse",
            "Nova Field",
            "Northern Lights",
            "Electronic",
            2014,
            198,
            .present,
            "Library/crimson"
        ),
        track(3, "Ember Waltz", "Paper Lanterns", "Slow Burn", "Jazz", 1995, 312, .present, "Library/ember"),
        track(4, "Frostbite", "Glass Harbour", "Winterlong", "Electronic", 2020, 176, .missing, "Library/frost"),
        track(5, "Golden Hour", "Paper Lanterns", "Slow Burn", nil, 2008, 265, .present, "Library/golden"),
        track(6, "Hidden Track", "Other Owner", "Elsewhere", "Rock", 1999, 200, .present, "Other/hidden"),
    ]

    /// The playing order `playlistID` is seeded with — deliberately NOT id order,
    /// so a test can tell "playlist order" from "library order".
    static let playlistOrder: [Int64] = [3, 1, 5]

    // swiftlint:disable:next function_parameter_count
    private static func track(
        _ id: Int64,
        _ title: String,
        _ artist: String,
        _ album: String,
        _ genre: String?,
        _ year: Int,
        _ duration: Double,
        _ availability: Availability,
        _ stem: String
    ) -> TrackRecord {
        TrackRecord(
            id: id,
            filePath: "\(pathPrefix)/\(stem).flac",
            title: title,
            sortTitle: title,
            artistName: artist,
            albumTitle: album,
            duration: duration,
            availability: availability,
            dateAdded: 1000 + Double(id),
            genre: genre,
            year: year
        )
    }
}

// MARK: - Database

extension ToolboxFixtures {
    /// A migrated in-memory database seeded with the table above, the filler rows,
    /// audio features, play events and two playlists.
    ///
    /// Only the OTHER profile gets a `libraryRoot`. That is what makes track 6
    /// owned (and therefore invisible to ``profileID``) while every other row stays
    /// ownerless and visible — the smallest seed that exercises `LibraryVisibility`
    /// in both directions.
    static func makeLibrary() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            try insertProfile(db, id: profileID, name: "Listener")
            try insertProfile(db, id: otherProfileID, name: "Other")
            var root = LibraryRootRecord(profileId: otherProfileID, path: "\(pathPrefix)/Other")
            try root.insert(db)
            for var record in libraryTracks {
                try record.insert(db)
            }
            try seedFiller(db)
            try seedAudioFeatures(db)
            try seedPlayEvents(db)
            try seedPlaylists(db)
        }
        return database
    }

    private static func insertProfile(_ db: Database, id: Int64, name: String) throws {
        var profile = ProfileRecord(id: id, name: name, createdAt: referenceNow)
        try profile.insert(db)
    }

    /// `fillerCount` rows sharing one searchable token, so a single query can
    /// return far more rows than any profile renders.
    private static func seedFiller(_ db: Database) throws {
        for index in 0 ..< fillerCount {
            let ordinal = index < 10 ? "0\(index)" : String(index)
            var record = TrackRecord(
                id: 100 + Int64(index),
                filePath: "\(pathPrefix)/Filler/probe\(ordinal).flac",
                title: "Fillerton Probe \(ordinal)",
                sortTitle: "Fillerton Probe \(ordinal)",
                artistName: "Fillerton",
                albumTitle: "Probes",
                duration: 120,
                availability: .present,
                dateAdded: 5000 + Double(index),
                genre: "Filler",
                year: 2024
            )
            try record.insert(db)
        }
    }

    /// Tracks 1–3 are analysed (3 with no reliable beat); 4 and 5 never were.
    private static func seedAudioFeatures(_ db: Database) throws {
        try TrackAudioFeatureRecord(
            trackId: 1, fileSize: 1, mtime: 0, bpm: 92,
            energy: 0.35, brightness: 0.40, analysisVersion: 1, computedAt: 0
        ).insert(db)
        try TrackAudioFeatureRecord(
            trackId: 2, fileSize: 1, mtime: 0, bpm: 128,
            energy: 0.82, brightness: 0.71, analysisVersion: 1, computedAt: 0
        ).insert(db)
        try TrackAudioFeatureRecord(
            trackId: 3, fileSize: 1, mtime: 0, bpm: nil,
            energy: 0.25, brightness: 0.30, analysisVersion: 1, computedAt: 0
        ).insert(db)
    }

    /// Six plays across three tracks, all inside the seven-day window: Crimson
    /// Pulse ×3 (completed), Ember Waltz ×2 (completed), Aurora Drift ×1 (skipped).
    /// So the top track, top artist and skip rate all have a single right answer.
    private static func seedPlayEvents(_ db: Database) throws {
        try insertPlays(db, count: 3, trackId: 2, daysAgo: 1, skipped: false)
        try insertPlays(db, count: 2, trackId: 3, daysAgo: 2, skipped: false)
        try insertPlays(db, count: 1, trackId: 1, daysAgo: 3, skipped: true)
    }

    private static func insertPlays(
        _ db: Database,
        count: Int,
        trackId: Int64,
        daysAgo: Double,
        skipped: Bool
    ) throws {
        guard let source = libraryTracks.first(where: { $0.id == trackId }) else { return }
        for index in 0 ..< count {
            var event = PlayEventRecord(
                profileId: profileID,
                trackId: trackId,
                artistName: source.artistName,
                title: source.title,
                albumTitle: source.albumTitle,
                genre: source.genre,
                durationSeconds: source.duration,
                startedAt: referenceNow.timeIntervalSince1970 - (daysAgo * 86400) - Double(index),
                utcOffsetSeconds: 0,
                secondsListened: skipped ? 20 : (source.duration ?? 0),
                completionFraction: skipped ? 0.1 : 1.0,
                skipped: skipped
            )
            try event.insert(db)
        }
    }

    private static func seedPlaylists(_ db: Database) throws {
        var owned = PlaylistRecord(id: playlistID, name: "Evening Set", profileId: profileID)
        try owned.insert(db)
        for (position, trackId) in playlistOrder.enumerated() {
            var entry = PlaylistTrackRecord(playlistId: playlistID, trackId: trackId, position: position)
            try entry.insert(db)
        }
        var foreign = PlaylistRecord(id: otherPlaylistID, name: "Not Yours", profileId: otherProfileID)
        try foreign.insert(db)
    }
}

// MARK: - Genre-seeded variants

extension ToolboxFixtures {
    /// Where the seeded genre block starts, clear of the six named tracks and of
    /// the filler run at 100.
    static let genreSeedFirstID: Int64 = 1000

    /// The standard library plus a block of tracks under ONE genre: `present` of
    /// them playable, `unavailable` of them not.
    ///
    /// Titles are zero-padded, so the `(sortTitle, id)` order the materialiser
    /// returns is the order a test can write down. The unplayable rows sort AFTER
    /// the playable ones, so a materialisation that forgot `availability` shows up
    /// as extra ids on the tail rather than as a reshuffle.
    static func makeLibrary(
        seedingGenre genre: String,
        present: Int,
        unavailable: Int = 0
    ) throws -> AppDatabase {
        let database = try makeLibrary()
        try database.writer.write { db in
            for index in 0 ..< (present + unavailable) {
                var record = genreTrack(genre: genre, index: index, isPresent: index < present)
                try record.insert(db)
            }
        }
        return database
    }

    /// The ids of the PLAYABLE seeded tracks, in materialisation order.
    static func genreTrackIDs(present: Int) -> [Int64] {
        (0 ..< present).map { genreSeedFirstID + Int64($0) }
    }

    private static func genreTrack(genre: String, index: Int, isPresent: Bool) -> TrackRecord {
        let ordinal = String(format: "%04d", index)
        let unplayable: Availability = index.isMultiple(of: 2) ? .missing : .externalOffline
        return TrackRecord(
            id: genreSeedFirstID + Int64(index),
            filePath: "\(pathPrefix)/Seeded/track\(ordinal).flac",
            title: "Seeded \(ordinal)",
            sortTitle: "Seeded \(ordinal)",
            artistName: "Seeded Artist",
            albumTitle: "Seeded Album",
            duration: 200,
            availability: isPresent ? .present : unplayable,
            dateAdded: 9000 + Double(index),
            genre: genre,
            year: 2010
        )
    }
}

// MARK: - Toolbox assembly

extension ToolboxFixtures {
    /// A toolbox over the seeded database, the REAL repositories and the REAL
    /// digest builder — only the proposal filer is a fake, because filing is the
    /// one thing that leaves this layer.
    static func makeToolbox(
        _ database: AppDatabase,
        filer: FakeToolboxProposalFiler = FakeToolboxProposalFiler(),
        playback: (any ToolboxPlaybackControlling)? = nil,
        profileId: Int64 = ToolboxFixtures.profileID
    ) -> LibraryToolbox {
        LibraryToolbox(context: LibraryToolboxContext(
            tracks: TrackRepository(database),
            playlists: PlaylistRepository(database),
            digests: ListeningDigestBuilder(database, now: { referenceNow }),
            reader: ToolboxLibraryReader(database),
            proposals: filer,
            playback: playback,
            profileId: profileId,
            now: { referenceNow }
        ))
    }

    /// The toolbox as a caller WITH a playback grant sees it, over a recording
    /// player. Returns both halves so a test can assert the answer AND what
    /// reached the seam — the two things a control tool has to get right at once.
    static func makeControllableToolbox(
        _ database: AppDatabase,
        profileId: Int64 = ToolboxFixtures.profileID
    ) -> (toolbox: LibraryToolbox, player: FakeToolboxPlaybackController) {
        let player = FakeToolboxPlaybackController(known: playerEntries)
        return (makeToolbox(database, playback: player, profileId: profileId), player)
    }

    /// Display text for the six named fixture tracks, so a rendered control row is
    /// assertable verbatim rather than as "Track 3".
    static let playerEntries: [Int64: ToolboxPlaybackEntry] = Dictionary(
        uniqueKeysWithValues: libraryTracks.compactMap { record in
            record.id.map { id in
                (id, ToolboxPlaybackEntry(
                    trackId: id,
                    title: record.title,
                    artist: record.artistName,
                    durationSeconds: record.duration
                ))
            }
        }
    )

    /// Every playlist row currently in the database — the "nothing was written"
    /// assertion for `propose_playlist`.
    static func playlistNames(_ database: AppDatabase) throws -> [String] {
        try database.writer.read { db in
            try PlaylistRecord.order(PlaylistRecord.Columns.name).fetchAll(db).map(\.name)
        }
    }
}

// MARK: - Proposal filing fake

/// Records what was filed and can be told to fail. Never writes anything — which
/// is the point: the production conformer cannot reach a repository either.
actor FakeToolboxProposalFiler: ToolboxProposalFiling {
    /// The id every successful filing reports, fixed so a test can assert it.
    let identifier: UUID
    private(set) var filed: [ToolboxPlaylistProposal] = []
    private var failure: (any Error)?

    init(identifier: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE") ?? UUID()) {
        self.identifier = identifier
    }

    func setFailure(_ failure: (any Error)?) {
        self.failure = failure
    }

    func fileCreatePlaylistProposal(_ proposal: ToolboxPlaylistProposal) async throws -> UUID {
        if let failure { throw failure }
        filed.append(proposal)
        return identifier
    }
}

/// A stand-in failure for the filing path.
struct ToolboxFilingFailure: Error, Equatable {}
