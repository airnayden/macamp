import Foundation
import GRDB

/// A persisted iOS security-scoped bookmark (and, where relevant, macOS).
///
/// Maps the `bookmark` table:
/// `(id, scope NOT NULL, bookmarkData BLOB NOT NULL, resolvedPath)`. The opaque
/// `bookmarkData` blob is produced by `URL.bookmarkData(options:)` and resolved
/// back to a live, access-scoped URL on demand.
public struct BookmarkRecord: Codable, Sendable, Equatable, Hashable {
    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Caller-defined scope/category for the bookmark (e.g. a library root tag).
    public var scope: String
    /// Opaque security-scoped bookmark blob.
    public var bookmarkData: Data
    /// The last successfully resolved filesystem path, for display/diagnostics.
    public var resolvedPath: String?

    public init(
        id: Int64? = nil,
        scope: String,
        bookmarkData: Data,
        resolvedPath: String? = nil
    ) {
        self.id = id
        self.scope = scope
        self.bookmarkData = bookmarkData
        self.resolvedPath = resolvedPath
    }
}

extension BookmarkRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookmark"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let scope = Column(CodingKeys.scope)
        public static let bookmarkData = Column(CodingKeys.bookmarkData)
        public static let resolvedPath = Column(CodingKeys.resolvedPath)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
