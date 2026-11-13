import GRDB

/// Per-profile state for one track — favourite flag, play/listen counts, and custom
/// ordering. Rows are **sparse**: one exists only once a profile actually favourites,
/// plays or reorders a track.
///
/// Maps the `profileTrackState` table, whose primary key is the composite
/// `(profileId, trackId)` — there is **no** separate `id` column. Both foreign keys
/// cascade, so deleting a profile (or a track) drops its state. Because the primary
/// key is caller-supplied rather than an auto-increment rowid, this conforms to
/// `PersistableRecord` (not `MutablePersistableRecord`): there is nothing to write
/// back after insert.
public struct ProfileTrackStateRecord: Codable, Sendable, Equatable, Hashable {
    /// Owning profile (`ON DELETE CASCADE`). Half of the composite primary key.
    public var profileId: Int64
    /// Referenced track (`ON DELETE CASCADE`). Half of the composite primary key.
    public var trackId: Int64
    /// Whether this profile marked the track a favourite. Stored as INTEGER 0/1
    /// (GRDB maps `Bool` automatically), matching ``TrackRecord/isFavourite``.
    public var isFavourite: Bool
    /// Completed plays of this track by this profile.
    public var playCount: Int
    /// Completed "listened" plays (≥ the listen threshold) by this profile.
    public var listenedCount: Int
    /// User-defined display position within this profile's views, or `nil`.
    public var customPosition: Int?

    public init(
        profileId: Int64,
        trackId: Int64,
        isFavourite: Bool = false,
        playCount: Int = 0,
        listenedCount: Int = 0,
        customPosition: Int? = nil
    ) {
        self.profileId = profileId
        self.trackId = trackId
        self.isFavourite = isFavourite
        self.playCount = playCount
        self.listenedCount = listenedCount
        self.customPosition = customPosition
    }
}

extension ProfileTrackStateRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profileTrackState"

    public enum Columns {
        public static let profileId = Column(CodingKeys.profileId)
        public static let trackId = Column(CodingKeys.trackId)
        public static let isFavourite = Column(CodingKeys.isFavourite)
        public static let playCount = Column(CodingKeys.playCount)
        public static let listenedCount = Column(CodingKeys.listenedCount)
        public static let customPosition = Column(CodingKeys.customPosition)
    }
}
