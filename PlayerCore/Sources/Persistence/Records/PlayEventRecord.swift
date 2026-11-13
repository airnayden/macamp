import Foundation
import GRDB

/// One play, captured with everything needed to describe it forever.
///
/// Maps the `playEvent` table. The metadata is **denormalised on purpose**: the
/// artist, title, album and genre are snapshotted at capture so the history survives
/// deleting the track, the playlist, or the whole library root it came from. For the
/// same reason ``trackId`` is a plain optional `Int64` with **no foreign key** — a
/// best-effort backlink, never a lifetime dependency. Only ``profileId`` cascades.
public struct PlayEventRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Owning profile (`ON DELETE CASCADE`).
    public var profileId: Int64
    /// The library track this play came from, or `nil` when it had none. Not a foreign
    /// key: the referenced row may be long gone.
    public var trackId: Int64?
    /// Artist as known at capture time.
    public var artistName: String?
    /// Title as known at capture time.
    public var title: String?
    /// Album as known at capture time.
    public var albumTitle: String?
    /// Genre as known at capture time.
    public var genre: String?
    /// Full track length in seconds, or `nil` when it was unknown.
    public var durationSeconds: Double?
    /// When the play began, as seconds since the Unix epoch.
    public var startedAt: TimeInterval
    /// Seconds east of GMT at capture. Lets hour-of-day facets mean the listener's
    /// own local time without consulting a `Calendar` at read time.
    public var utcOffsetSeconds: Int
    /// How much of the track was actually heard, in seconds.
    public var secondsListened: Double
    /// ``secondsListened`` over ``durationSeconds``, clamped by the writer.
    public var completionFraction: Double
    /// Whether the listener cut the track short.
    public var skipped: Bool
    /// Raw value of the surface playback started from, or `nil` when there was no
    /// navigable source.
    public var sourceSurface: String?
    /// Whether shuffle was on for this play.
    public var shuffle: Bool

    public init(
        id: Int64? = nil,
        profileId: Int64,
        trackId: Int64? = nil,
        artistName: String? = nil,
        title: String? = nil,
        albumTitle: String? = nil,
        genre: String? = nil,
        durationSeconds: Double? = nil,
        startedAt: TimeInterval,
        utcOffsetSeconds: Int,
        secondsListened: Double = 0,
        completionFraction: Double = 0,
        skipped: Bool = false,
        sourceSurface: String? = nil,
        shuffle: Bool = false
    ) {
        self.id = id
        self.profileId = profileId
        self.trackId = trackId
        self.artistName = artistName
        self.title = title
        self.albumTitle = albumTitle
        self.genre = genre
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.utcOffsetSeconds = utcOffsetSeconds
        self.secondsListened = secondsListened
        self.completionFraction = completionFraction
        self.skipped = skipped
        self.sourceSurface = sourceSurface
        self.shuffle = shuffle
    }
}

extension PlayEventRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playEvent"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let profileId = Column(CodingKeys.profileId)
        public static let trackId = Column(CodingKeys.trackId)
        public static let artistName = Column(CodingKeys.artistName)
        public static let title = Column(CodingKeys.title)
        public static let albumTitle = Column(CodingKeys.albumTitle)
        public static let genre = Column(CodingKeys.genre)
        public static let durationSeconds = Column(CodingKeys.durationSeconds)
        public static let startedAt = Column(CodingKeys.startedAt)
        public static let utcOffsetSeconds = Column(CodingKeys.utcOffsetSeconds)
        public static let secondsListened = Column(CodingKeys.secondsListened)
        public static let completionFraction = Column(CodingKeys.completionFraction)
        public static let skipped = Column(CodingKeys.skipped)
        public static let sourceSurface = Column(CodingKeys.sourceSurface)
        public static let shuffle = Column(CodingKeys.shuffle)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
