import GRDB

/// The rule set that powers a smart playlist.
///
/// Maps the `smartPlaylist` table:
/// `(id, playlistId → playlist UNIQUE, rulesJson NOT NULL, rulesVersion NOT NULL
/// DEFAULT 1, lastEvaluatedAt)`. Exactly one row may exist per playlist
/// (`playlistId` is `UNIQUE`).
public struct SmartPlaylistRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// The owning playlist (`UNIQUE`, `ON DELETE CASCADE`).
    public var playlistId: Int64
    /// JSON-encoded smart-playlist rules.
    public var rulesJson: String
    /// Schema version of ``rulesJson``. Rows written before v16 read back as `1`.
    public var rulesVersion: Int
    /// When the rules last evaluated, or `nil` if they never have.
    public var lastEvaluatedAt: Double?

    public init(
        id: Int64? = nil,
        playlistId: Int64,
        rulesJson: String,
        rulesVersion: Int = 1,
        lastEvaluatedAt: Double? = nil
    ) {
        self.id = id
        self.playlistId = playlistId
        self.rulesJson = rulesJson
        self.rulesVersion = rulesVersion
        self.lastEvaluatedAt = lastEvaluatedAt
    }
}

extension SmartPlaylistRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "smartPlaylist"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let playlistId = Column(CodingKeys.playlistId)
        public static let rulesJson = Column(CodingKeys.rulesJson)
        public static let rulesVersion = Column(CodingKeys.rulesVersion)
        public static let lastEvaluatedAt = Column(CodingKeys.lastEvaluatedAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Associations

public extension SmartPlaylistRecord {
    /// The owning playlist (`smartPlaylist.playlistId → playlist.id`).
    static let playlist = belongsTo(PlaylistRecord.self)

    /// A request for the owning playlist.
    var playlist: QueryInterfaceRequest<PlaylistRecord> {
        request(for: SmartPlaylistRecord.playlist)
    }
}
