import GRDB

/// A musical artist.
///
/// Maps the `artist` table: `(id, name, sortName NOT NULL, mbid)`.
public struct ArtistRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Display name. Nullable in the schema.
    public var name: String?
    /// Locale-aware sorting key (e.g. "Beatles, The"). Required.
    public var sortName: String
    /// MusicBrainz artist id, when known.
    public var mbid: String?

    public init(
        id: Int64? = nil,
        name: String? = nil,
        sortName: String,
        mbid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.mbid = mbid
    }
}

extension ArtistRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "artist"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let sortName = Column(CodingKeys.sortName)
        public static let mbid = Column(CodingKeys.mbid)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

public extension ArtistRecord {
    /// All albums credited to this artist (`album.artistId → artist.id`).
    static let albums = hasMany(AlbumRecord.self)
    /// All tracks credited to this artist (`track.artistId → artist.id`).
    static let tracks = hasMany(TrackRecord.self)

    /// A request for this artist's albums.
    var albums: QueryInterfaceRequest<AlbumRecord> {
        request(for: ArtistRecord.albums)
    }

    /// A request for this artist's tracks.
    var tracks: QueryInterfaceRequest<TrackRecord> {
        request(for: ArtistRecord.tracks)
    }
}
