import GRDB

/// An album.
///
/// Maps the `album` table: `(id, title, sortTitle, artistId → artist, year, mbid)`.
public struct AlbumRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Display title. Nullable in the schema.
    public var title: String?
    /// Locale-aware sorting key.
    public var sortTitle: String?
    /// Owning artist (`ON DELETE SET NULL`).
    public var artistId: Int64?
    /// Release year, when known.
    public var year: Int?
    /// MusicBrainz release-group id, when known.
    public var mbid: String?

    public init(
        id: Int64? = nil,
        title: String? = nil,
        sortTitle: String? = nil,
        artistId: Int64? = nil,
        year: Int? = nil,
        mbid: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle
        self.artistId = artistId
        self.year = year
        self.mbid = mbid
    }
}

extension AlbumRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "album"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let title = Column(CodingKeys.title)
        public static let sortTitle = Column(CodingKeys.sortTitle)
        public static let artistId = Column(CodingKeys.artistId)
        public static let year = Column(CodingKeys.year)
        public static let mbid = Column(CodingKeys.mbid)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

public extension AlbumRecord {
    /// The album's artist (`album.artistId → artist.id`).
    static let artist = belongsTo(ArtistRecord.self)
    /// All tracks on this album (`track.albumId → album.id`).
    static let tracks = hasMany(TrackRecord.self)

    /// A request for this album's artist.
    var artist: QueryInterfaceRequest<ArtistRecord> {
        request(for: AlbumRecord.artist)
    }

    /// A request for this album's tracks.
    var tracks: QueryInterfaceRequest<TrackRecord> {
        request(for: AlbumRecord.tracks)
    }
}
