import Foundation
import GRDB

/// Off-actor read/write access to the single playback-state row owned by a profile.
public protocol ProfilePlaybackStateRepositoryProviding: Sendable {
    /// Atomically inserts or replaces the row for `profileId`.
    func upsert(
        for profileId: Int64,
        snapshotJson: String,
        sourceJson: String?,
        savedAt: TimeInterval
    ) async throws

    /// Returns the profile's saved playback state, if one exists.
    func fetch(for profileId: Int64) async throws -> ProfilePlaybackStateRecord?

    /// Deletes the profile's saved playback state, if one exists.
    func delete(for profileId: Int64) async throws
}

/// The concrete ``ProfilePlaybackStateRepositoryProviding`` over a GRDB writer.
///
/// Every operation uses GRDB's async reader/writer overload so a main-actor caller
/// never waits synchronously on a database connection.
public struct ProfilePlaybackStateRepository: ProfilePlaybackStateRepositoryProviding {
    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func upsert(
        for profileId: Int64,
        snapshotJson: String,
        sourceJson: String?,
        savedAt: TimeInterval
    ) async throws {
        let record = ProfilePlaybackStateRecord(
            profileId: profileId,
            snapshotJson: snapshotJson,
            sourceJson: sourceJson,
            savedAt: savedAt
        )
        try await dbWriter.write { db in try record.upsert(db) }
    }

    public func fetch(for profileId: Int64) async throws -> ProfilePlaybackStateRecord? {
        try await dbWriter.read { db in
            try ProfilePlaybackStateRecord.fetchOne(db, key: profileId)
        }
    }

    public func delete(for profileId: Int64) async throws {
        try await dbWriter.write { db in
            _ = try ProfilePlaybackStateRecord.deleteOne(db, key: profileId)
        }
    }
}
