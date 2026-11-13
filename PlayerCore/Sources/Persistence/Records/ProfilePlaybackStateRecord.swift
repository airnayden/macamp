import Foundation
import GRDB

/// The last playback snapshot saved for one profile.
///
/// Maps `profilePlaybackState`, keyed directly by `profileId`. Both JSON fields
/// are opaque to Persistence: Services owns the snapshot/source encoding. The
/// optional `sourceJson` remains `nil` when playback has no navigable source.
public struct ProfilePlaybackStateRecord: Codable, Sendable, Equatable, Hashable {
    /// Owning profile and the table's caller-supplied primary key.
    public var profileId: Int64
    /// An encoded coordinator snapshot.
    public var snapshotJson: String
    /// An encoded playback source, or `nil` when no source was captured.
    public var sourceJson: String?
    /// Save time as seconds since the Unix epoch (`REAL` in SQLite).
    public var savedAt: TimeInterval

    public init(
        profileId: Int64,
        snapshotJson: String,
        sourceJson: String? = nil,
        savedAt: TimeInterval
    ) {
        self.profileId = profileId
        self.snapshotJson = snapshotJson
        self.sourceJson = sourceJson
        self.savedAt = savedAt
    }
}

extension ProfilePlaybackStateRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profilePlaybackState"

    public enum Columns {
        public static let profileId = Column(CodingKeys.profileId)
        public static let snapshotJson = Column(CodingKeys.snapshotJson)
        public static let sourceJson = Column(CodingKeys.sourceJson)
        public static let savedAt = Column(CodingKeys.savedAt)
    }
}
