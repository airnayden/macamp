import Foundation
import GRDB

/// A user profile — one per household member — that scopes library roots, playlists
/// and per-track state. Every install ships with the built-in **Guest** profile
/// (``guestID``, id 1), which is ownerless and can never be deleted.
///
/// Maps the `profile` table:
/// `(id, name NOT NULL, lastName, bio, avatarId NOT NULL DEFAULT 'waveform-vice',
/// pinHash, pinSalt, createdAt NOT NULL)`.
public struct ProfileRecord: Codable, Sendable, Equatable, Hashable {
    /// The built-in Guest profile's id. Seeded by the `v12` migration; the UI
    /// localises its display name, so the stored ``name`` is only the plain "Guest"
    /// fallback. Delete is forbidden for this id (``ProfileRepositoryError/guestUndeletable``).
    public static let guestID: Int64 = 1

    /// The default avatar preset assigned to a new profile (matches the `v12`
    /// column default).
    public static let defaultAvatarID = "waveform-vice"

    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Display name. Required.
    public var name: String
    /// Optional last name.
    public var lastName: String?
    /// Optional free-text bio.
    public var bio: String?
    /// The chosen avatar preset identifier. Defaults to the shipped `waveform-vice`.
    /// Used only when ``avatarImagePath`` is `nil`.
    public var avatarId: String
    /// Absolute path to a custom avatar image (a downsampled PNG the shell copied
    /// into Application Support), or `nil` to render the ``avatarId`` preset.
    public var avatarImagePath: String?
    /// Salt-prefixed SHA-256 PIN hash, or `nil` when the profile has no PIN.
    public var pinHash: String?
    /// The PIN salt, or `nil` when the profile has no PIN.
    public var pinSalt: String?
    /// When the profile was created.
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        lastName: String? = nil,
        bio: String? = nil,
        avatarId: String = ProfileRecord.defaultAvatarID,
        avatarImagePath: String? = nil,
        pinHash: String? = nil,
        pinSalt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.lastName = lastName
        self.bio = bio
        self.avatarId = avatarId
        self.avatarImagePath = avatarImagePath
        self.pinHash = pinHash
        self.pinSalt = pinSalt
        self.createdAt = createdAt
    }
}

extension ProfileRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "profile"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let lastName = Column(CodingKeys.lastName)
        public static let bio = Column(CodingKeys.bio)
        public static let avatarId = Column(CodingKeys.avatarId)
        public static let avatarImagePath = Column(CodingKeys.avatarImagePath)
        public static let pinHash = Column(CodingKeys.pinHash)
        public static let pinSalt = Column(CodingKeys.pinSalt)
        public static let createdAt = Column(CodingKeys.createdAt)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
