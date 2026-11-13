import GRDB

/// An ordered membership row linking a ``TrackRecord`` into a ``PlaylistRecord``.
///
/// Maps the `playlistTrack` table:
/// `(id, playlistId → playlist, trackId → track, position NOT NULL)` with a
/// `UNIQUE(playlistId, position)` constraint that doubles as the ordering index.
public struct PlaylistTrackRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Owning playlist (`ON DELETE CASCADE`).
    public var playlistId: Int64
    /// Referenced track (`ON DELETE CASCADE`).
    public var trackId: Int64
    /// 0-based (or 1-based, by convention of the caller) position within the
    /// playlist. Unique per `playlistId`.
    public var position: Int

    public init(
        id: Int64? = nil,
        playlistId: Int64,
        trackId: Int64,
        position: Int
    ) {
        self.id = id
        self.playlistId = playlistId
        self.trackId = trackId
        self.position = position
    }
}

extension PlaylistTrackRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlistTrack"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let playlistId = Column(CodingKeys.playlistId)
        public static let trackId = Column(CodingKeys.trackId)
        public static let position = Column(CodingKeys.position)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

public extension PlaylistTrackRecord {
    /// The owning playlist (`playlistTrack.playlistId → playlist.id`).
    static let playlist = belongsTo(PlaylistRecord.self)
    /// The referenced track (`playlistTrack.trackId → track.id`).
    static let track = belongsTo(TrackRecord.self)

    /// A request for the owning playlist.
    var playlist: QueryInterfaceRequest<PlaylistRecord> {
        request(for: PlaylistTrackRecord.playlist)
    }

    /// A request for the referenced track.
    var track: QueryInterfaceRequest<TrackRecord> {
        request(for: PlaylistTrackRecord.track)
    }
}
