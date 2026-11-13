import GRDB

/// One track's manual position within one library root, for one profile.
///
/// Maps the `folderTrackOrder` table, whose primary key is the composite
/// `(profileId, rootPath, trackId)` — there is **no** separate `id` column, so this
/// conforms to `PersistableRecord` (not `MutablePersistableRecord`): there is nothing
/// to write back after insert.
///
/// Keyed by root rather than held as a single per-track column because nested and
/// overlapping roots each need an independent order. Both foreign keys cascade —
/// unlike `playEvent`, ordering carries no survivability duty. Favourites keep their
/// own `profileTrackState.customPosition`; the two orderings never share state.
public struct FolderTrackOrderRecord: Codable, Sendable, Equatable, Hashable {
    /// Owning profile (`ON DELETE CASCADE`). Part of the composite primary key.
    public var profileId: Int64
    /// The library root this ordering belongs to. Part of the composite primary key.
    public var rootPath: String
    /// Referenced track (`ON DELETE CASCADE`). Part of the composite primary key.
    public var trackId: Int64
    /// Display position within the root, ascending.
    public var position: Int

    public init(
        profileId: Int64,
        rootPath: String,
        trackId: Int64,
        position: Int
    ) {
        self.profileId = profileId
        self.rootPath = rootPath
        self.trackId = trackId
        self.position = position
    }
}

extension FolderTrackOrderRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folderTrackOrder"

    public enum Columns {
        public static let profileId = Column(CodingKeys.profileId)
        public static let rootPath = Column(CodingKeys.rootPath)
        public static let trackId = Column(CodingKeys.trackId)
        public static let position = Column(CodingKeys.position)
    }
}
