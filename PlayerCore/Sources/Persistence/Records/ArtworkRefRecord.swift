import GRDB

/// A content-addressed reference to a cached artwork image on disk.
///
/// Maps the `artworkRef` table:
/// `(id, contentHash UNIQUE NOT NULL, diskPath NOT NULL, width, height)`.
/// De-duplication is by `contentHash`, so identical artwork shared across many
/// tracks is stored only once.
public struct ArtworkRefRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Stable content hash of the image bytes. `UNIQUE NOT NULL`.
    public var contentHash: String
    /// On-disk path of the cached image. Required.
    public var diskPath: String
    /// Pixel width, when known.
    public var width: Int?
    /// Pixel height, when known.
    public var height: Int?

    public init(
        id: Int64? = nil,
        contentHash: String,
        diskPath: String,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.diskPath = diskPath
        self.width = width
        self.height = height
    }
}

extension ArtworkRefRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "artworkRef"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let contentHash = Column(CodingKeys.contentHash)
        public static let diskPath = Column(CodingKeys.diskPath)
        public static let width = Column(CodingKeys.width)
        public static let height = Column(CodingKeys.height)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
