// InfoCacheStore — GRDB-backed persistence for resolved online info (migration "v9").
//
// Narrative info (artist biography, album story, track description) is expensive to
// resolve — two MusicBrainz hops plus a Wikipedia fetch, all rate-limited — so it is
// cached as JSON in the `infoCache` table keyed by (entityType, entityKey). A cached
// row older than `maxAge` (30 days by default) is treated as a miss so the info is
// periodically refreshed.
//
// Access is async (`writer.read`/`writer.write`), so a cache lookup never blocks the
// caller's thread (the UI reads it from a `.task`). This file MUST NOT import AppKit
// or UIKit (PlayerCore portability invariant).
import Foundation
import GRDB
import Metadata
import Persistence

/// A GRDB-backed cache for ``ArtistInfo`` / ``AlbumInfo`` / ``TrackInfo`` JSON,
/// keyed by `(entityType, entityKey)`, with time-based expiry.
public struct InfoCacheStore: Sendable {
    /// The default cache lifetime: 30 days.
    public static let defaultMaxAge: TimeInterval = 30 * 86400

    private let writer: any DatabaseWriter
    private let maxAge: TimeInterval

    public init(_ appDatabase: AppDatabase, maxAge: TimeInterval = InfoCacheStore.defaultMaxAge) {
        writer = appDatabase.writer
        self.maxAge = maxAge
    }

    public init(writer: any DatabaseWriter, maxAge: TimeInterval = InfoCacheStore.defaultMaxAge) {
        self.writer = writer
        self.maxAge = maxAge
    }

    /// Returns the decoded value for `(entityType, entityKey)`, or `nil` when absent,
    /// expired, or undecodable. `now` is injectable so a test can force expiry.
    public func load<Value: Decodable & Sendable>(
        _: Value.Type,
        entityType: String,
        entityKey: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) async throws -> Value? {
        let maxAge = maxAge
        let json = try await writer.read { db -> String? in
            guard let record = try Self.request(entityType: entityType, entityKey: entityKey).fetchOne(db) else {
                return nil
            }
            if let fetchedAt = record.fetchedAt, fetchedAt + maxAge < now {
                return nil
            }
            return record.infoJson
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Upserts the JSON encoding of `value` under `(entityType, entityKey)`, stamping
    /// `fetchedAt` so later loads can expire it.
    public func store(
        _ value: some Encodable & Sendable,
        entityType: String,
        entityKey: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) async throws {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try await writer.write { db in
            var record = InfoCacheRecord(
                id: nil,
                entityType: entityType,
                entityKey: entityKey,
                infoJson: json,
                fetchedAt: now
            )
            if let existing = try Self.request(entityType: entityType, entityKey: entityKey).fetchOne(db) {
                record.id = existing.id
            }
            try record.save(db)
        }
    }

    private static func request(entityType: String, entityKey: String) -> QueryInterfaceRequest<InfoCacheRecord> {
        InfoCacheRecord
            .filter(InfoCacheRecord.Columns.entityType == entityType)
            .filter(InfoCacheRecord.Columns.entityKey == entityKey)
    }
}

/// A GRDB record mapping a cached info payload to the `infoCache` table.
struct InfoCacheRecord: Codable, Equatable {
    var id: Int64?
    var entityType: String
    var entityKey: String
    var infoJson: String
    var fetchedAt: Double?
}

extension InfoCacheRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "infoCache"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let entityType = Column(CodingKeys.entityType)
        static let entityKey = Column(CodingKeys.entityKey)
        static let infoJson = Column(CodingKeys.infoJson)
        static let fetchedAt = Column(CodingKeys.fetchedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
