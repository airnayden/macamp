import GRDB

/// Provenance for a playlist that a generator produced.
///
/// Maps the `generatedPlaylist` table:
/// `(id, playlistId → playlist UNIQUE, generatorKind NOT NULL, specJson NOT NULL,
/// specVersion NOT NULL, lastRefreshedAt)`. Exactly one row may exist per playlist
/// (`playlistId` is `UNIQUE`), mirroring ``SmartPlaylistRecord``.
///
/// ``specJson`` is opaque to Persistence — the owning service defines its shape and
/// versions it through ``specVersion``.
public struct GeneratedPlaylistRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// The generated playlist (`UNIQUE`, `ON DELETE CASCADE`).
    public var playlistId: Int64
    /// Which generator produced the playlist, e.g. `daypartMix` or `rediscovery`.
    public var generatorKind: String
    /// JSON-encoded generator spec.
    public var specJson: String
    /// Schema version of ``specJson``.
    public var specVersion: Int
    /// When the playlist last regenerated, or `nil` if it never has.
    public var lastRefreshedAt: Double?

    public init(
        id: Int64? = nil,
        playlistId: Int64,
        generatorKind: String,
        specJson: String,
        specVersion: Int,
        lastRefreshedAt: Double? = nil
    ) {
        self.id = id
        self.playlistId = playlistId
        self.generatorKind = generatorKind
        self.specJson = specJson
        self.specVersion = specVersion
        self.lastRefreshedAt = lastRefreshedAt
    }
}

extension GeneratedPlaylistRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "generatedPlaylist"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let playlistId = Column(CodingKeys.playlistId)
        public static let generatorKind = Column(CodingKeys.generatorKind)
        public static let specJson = Column(CodingKeys.specJson)
        public static let specVersion = Column(CodingKeys.specVersion)
        public static let lastRefreshedAt = Column(CodingKeys.lastRefreshedAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

public extension GeneratedPlaylistRecord {
    /// The generated playlist (`generatedPlaylist.playlistId → playlist.id`).
    static let playlist = belongsTo(PlaylistRecord.self)

    /// A request for the generated playlist.
    var playlist: QueryInterfaceRequest<PlaylistRecord> {
        request(for: GeneratedPlaylistRecord.playlist)
    }
}
