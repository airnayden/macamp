import GRDB

/// A library-root folder owned by a profile. A profile sees tracks beneath its own
/// roots (plus ownerless tracks).
///
/// Maps the `libraryRoot` table: `(id, profileId → profile, path NOT NULL)` with a
/// `UNIQUE(profileId, path)` constraint that blocks a duplicate root. `ON DELETE
/// CASCADE` drops a profile's roots when the profile is deleted.
public struct LibraryRootRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Owning profile (`ON DELETE CASCADE`).
    public var profileId: Int64
    /// Absolute folder path.
    public var path: String

    public init(
        id: Int64? = nil,
        profileId: Int64,
        path: String
    ) {
        self.id = id
        self.profileId = profileId
        self.path = path
    }
}

extension LibraryRootRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "libraryRoot"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let profileId = Column(CodingKeys.profileId)
        public static let path = Column(CodingKeys.path)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
