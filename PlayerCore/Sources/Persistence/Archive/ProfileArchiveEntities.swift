// ProfileArchiveEntities — the value types that make up a `.macampprofile` payload.
//
// Every type here is a pure Foundation `Codable` value: no GRDB, no row ids, no file
// paths. That is a structural guarantee, not a filter — the archive CANNOT leak a
// `filePath`, an instrumental cache location, or a machine-local rowid because no
// field exists to carry one.
//
// Two absences are load-bearing and must stay absent:
//   * ``ProfileArchiveProfile`` has no `avatarImagePath` and no `pinHash`/`pinSalt`.
//   * Nothing here has a `trackId`. Tracks are identified by their SNAPSHOT
//     (`artist` / `title` / `album` / `duration`), and import re-resolves that to a
//     LOCAL rowid — see ``ProfileArchiveTrackMatcher``.
import Foundation

// MARK: - Profile identity

/// The portable half of a `profile` row.
///
/// The custom avatar image path and the PIN hash/salt are deliberately not modelled:
/// the first is machine-local, the second must never travel.
public struct ProfileArchiveProfile: Codable, Sendable, Equatable, Hashable {
    /// Display name.
    public var name: String
    /// Optional last name.
    public var lastName: String?
    /// Optional free-text bio.
    public var bio: String?
    /// The shipped avatar preset identifier (never a file path).
    public var avatarId: String
    /// Creation instant, in whole-or-fractional seconds since the Unix epoch.
    public var createdAt: Double

    public init(
        name: String,
        lastName: String? = nil,
        bio: String? = nil,
        avatarId: String,
        createdAt: Double
    ) {
        self.name = name
        self.lastName = lastName
        self.bio = bio
        self.avatarId = avatarId
        self.createdAt = createdAt
    }
}

// MARK: - Track identity

/// How the archive names a track, independently of any database.
///
/// This is the ONLY handle an archived row has on a song. Import matches it against
/// the local library (see ``ProfileArchiveTrackMatcher``); every statistics facet is
/// computed from these snapshot fields, so a track that matches nothing locally still
/// contributes its full history.
public struct ProfileArchiveTrackIdentity: Codable, Sendable, Equatable, Hashable {
    public var artistName: String?
    public var title: String?
    public var albumTitle: String?
    /// Track length in seconds. Compared with a ±1 s tolerance when matching, because
    /// two rips of one song rarely agree to the millisecond.
    public var durationSeconds: Double?

    public init(
        artistName: String? = nil,
        title: String? = nil,
        albumTitle: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.artistName = artistName
        self.title = title
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Statistics

/// One archived `playEvent` row.
public struct ProfileArchivePlayEvent: Codable, Sendable, Equatable, Hashable {
    public var track: ProfileArchiveTrackIdentity
    /// Genre as known at capture. Not part of the match key, but part of the snapshot.
    public var genre: String?
    /// When the play began, in seconds since the Unix epoch.
    public var startedAt: Double
    /// Seconds east of GMT at capture — what makes hour-of-day facets mean the
    /// listener's own local time on any machine.
    public var utcOffsetSeconds: Int
    public var secondsListened: Double
    public var completionFraction: Double
    public var skipped: Bool
    /// Raw surface value (`"library"`, `"playlist"`, …). Never a path: the folder
    /// surface collapses to the bare tag `"folder"` before it is ever stored.
    public var sourceSurface: String?
    public var shuffle: Bool

    public init(
        track: ProfileArchiveTrackIdentity,
        genre: String? = nil,
        startedAt: Double,
        utcOffsetSeconds: Int,
        secondsListened: Double,
        completionFraction: Double,
        skipped: Bool,
        sourceSurface: String? = nil,
        shuffle: Bool
    ) {
        self.track = track
        self.genre = genre
        self.startedAt = startedAt
        self.utcOffsetSeconds = utcOffsetSeconds
        self.secondsListened = secondsListened
        self.completionFraction = completionFraction
        self.skipped = skipped
        self.sourceSurface = sourceSurface
        self.shuffle = shuffle
    }
}

/// One archived `playEventRollup` row — a permanent monthly summary.
public struct ProfileArchiveRollup: Codable, Sendable, Equatable, Hashable {
    /// `"YYYY-MM"`, the UTC civil month.
    public var yearMonth: String
    public var artistKey: String
    public var genreKey: String
    public var plays: Int
    public var listenedSeconds: Double
    public var skips: Int
    public var completions: Int

    public init(
        yearMonth: String,
        artistKey: String,
        genreKey: String,
        plays: Int,
        listenedSeconds: Double,
        skips: Int,
        completions: Int
    ) {
        self.yearMonth = yearMonth
        self.artistKey = artistKey
        self.genreKey = genreKey
        self.plays = plays
        self.listenedSeconds = listenedSeconds
        self.skips = skips
        self.completions = completions
    }
}

/// One archived `playSegmentHeat` row — a per-track replay heatmap.
public struct ProfileArchiveSegmentHeat: Codable, Sendable, Equatable, Hashable {
    public var track: ProfileArchiveTrackIdentity
    public var genre: String?
    /// The raw 400-byte little-endian bucket blob. `JSONEncoder` renders `Data` as
    /// base64 by default, so this is a deterministic base64 string in the archive and
    /// the on-disk byte order survives the trip (the blob is explicitly
    /// little-endian, never host order — see `PlaySegmentHeatRecord`).
    public var bucketCounts: Data
    public var totalPasses: Int
    /// Last write instant, in seconds since the Unix epoch.
    public var updatedAt: Double

    public init(
        track: ProfileArchiveTrackIdentity,
        genre: String? = nil,
        bucketCounts: Data,
        totalPasses: Int,
        updatedAt: Double
    ) {
        self.track = track
        self.genre = genre
        self.bucketCounts = bucketCounts
        self.totalPasses = totalPasses
        self.updatedAt = updatedAt
    }
}

/// One archived `profileTrackState` row — this profile's counters for one track.
///
/// The table itself stores only ids and counters, so export JOINs each row to its
/// local track's snapshot and carries the identity HERE. That is what lets import
/// match by identity instead of trusting a foreign machine's rowids — and the join
/// deliberately takes only the four identity columns, never `filePath`.
public struct ProfileArchiveTrackState: Codable, Sendable, Equatable, Hashable {
    public var track: ProfileArchiveTrackIdentity
    public var isFavourite: Bool
    public var playCount: Int
    public var listenedCount: Int
    public var customPosition: Int?

    public init(
        track: ProfileArchiveTrackIdentity,
        isFavourite: Bool,
        playCount: Int,
        listenedCount: Int,
        customPosition: Int? = nil
    ) {
        self.track = track
        self.isFavourite = isFavourite
        self.playCount = playCount
        self.listenedCount = listenedCount
        self.customPosition = customPosition
    }
}

// MARK: - Equalizer

/// One custom EQ preset. Built-ins are code constants and are never archived.
public struct ProfileArchiveEQPreset: Codable, Sendable, Equatable, Hashable {
    public var name: String
    /// Exactly ``ProfileArchiveEQPreset/bandCount`` per-band gains in dB. Stored as
    /// `Double` so the JSON round-trip is exact for every `Float` value.
    public var bandGains: [Double]
    public var preamp: Double?

    /// The fixed 10-band ISO octave layout every preset must supply.
    public static let bandCount = 10

    public init(name: String, bandGains: [Double], preamp: Double? = nil) {
        self.name = name
        self.bandGains = bandGains
        self.preamp = preamp
    }
}
