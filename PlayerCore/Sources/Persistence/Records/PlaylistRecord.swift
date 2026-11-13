import GRDB

/// A playlist (either a plain ordered list or the container for a smart playlist).
///
/// Maps the `playlist` table:
/// `(id, name NOT NULL, isSmartPlaylist DEFAULT 0, profileId → profile)`.
public struct PlaylistRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Display name. Required.
    public var name: String
    /// Whether a ``SmartPlaylistRecord`` provides this playlist's contents.
    public var isSmartPlaylist: Bool
    /// Owning profile (`playlist.profileId → profile.id`, `ON DELETE CASCADE`).
    /// Nullable to mirror the `v12` FK ADD COLUMN; never `nil` in production
    /// (backfilled to Guest, and `create(named:profileId:)` always sets it).
    public var profileId: Int64?

    public init(
        id: Int64? = nil,
        name: String,
        isSmartPlaylist: Bool = false,
        profileId: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.isSmartPlaylist = isSmartPlaylist
        self.profileId = profileId
    }
}

extension PlaylistRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let isSmartPlaylist = Column(CodingKeys.isSmartPlaylist)
        public static let profileId = Column(CodingKeys.profileId)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

public extension PlaylistRecord {
    /// The ordered join rows for this playlist (`playlistTrack.playlistId → playlist.id`).
    static let playlistTracks = hasMany(PlaylistTrackRecord.self)
    /// The tracks of this playlist, reached through the join table.
    static let tracks = hasMany(
        TrackRecord.self,
        through: playlistTracks,
        using: PlaylistTrackRecord.track
    )
    /// The optional smart-playlist configuration (`smartPlaylist.playlistId → playlist.id`).
    static let smartPlaylist = hasOne(SmartPlaylistRecord.self)

    /// A request for this playlist's ordered join rows.
    var playlistTracks: QueryInterfaceRequest<PlaylistTrackRecord> {
        request(for: PlaylistRecord.playlistTracks)
    }

    /// A request for this playlist's tracks (through the join table).
    var tracks: QueryInterfaceRequest<TrackRecord> {
        request(for: PlaylistRecord.tracks)
    }

    /// A request for this playlist's smart configuration, if any.
    var smartPlaylist: QueryInterfaceRequest<SmartPlaylistRecord> {
        request(for: PlaylistRecord.smartPlaylist)
    }
}
