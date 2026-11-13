import Foundation
import GRDB

/// The GRDB-backed ``SmartPlaylistRepositoryProviding``.
///
/// Owns the transactions; the rule lowering lives in ``SmartPlaylistCompiler`` and the
/// materialisation in ``SmartPlaylistEvaluator``, both of which operate on a `Database`
/// so an evaluation is exactly one `write {}` — compiled `SELECT`, membership rewrite
/// and the `lastEvaluatedAt` stamp all commit or all roll back.
///
/// See ``SmartPlaylistRepositoryProviding`` for the materialisation contract and what
/// a manual reorder of a smart playlist means.
public struct SmartPlaylistRepository: SmartPlaylistRepositoryProviding {
    private let dbWriter: any DatabaseWriter
    private let now: @Sendable () -> Date

    /// - Parameter now: The clock the evaluator stamps `lastEvaluatedAt` from and
    ///   measures recency windows back from. Injected so staleness and
    ///   "played within N days" are testable on their exact boundaries.
    public init(_ appDatabase: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        dbWriter = appDatabase.writer
        self.now = now
    }

    public init(_ dbWriter: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbWriter = dbWriter
        self.now = now
    }

    @_disfavoredOverload
    @discardableResult
    public func setRules(
        _ rules: SmartPlaylistRules,
        forPlaylist playlistId: Int64
    ) throws -> SmartPlaylistRecord {
        let json = try rules.encodedJSON()
        return try dbWriter.write { db in
            try Self.save(db, json: json, version: rules.schemaVersion, playlistId: playlistId)
        }
    }

    @_disfavoredOverload
    public func rules(forPlaylist playlistId: Int64) throws -> SmartPlaylistRules? {
        try dbWriter.read { db in try Self.fetchRules(db, playlistId: playlistId) }
    }

    @_disfavoredOverload
    @discardableResult
    public func evaluate(playlistId: Int64) throws -> SmartPlaylistEvaluation {
        let instant = now()
        return try dbWriter.write { db in
            try SmartPlaylistEvaluator.evaluate(db, playlistId: playlistId, now: instant)
        }
    }

    @_disfavoredOverload
    public func isStale(playlistId: Int64, ttl: TimeInterval) throws -> Bool {
        let instant = now()
        return try dbWriter.read { db in
            try Self.isStale(db, playlistId: playlistId, ttl: ttl, now: instant)
        }
    }

    @_disfavoredOverload
    public func previewTrackIds(matching rules: SmartPlaylistRules, profileId: Int64) throws -> [Int64] {
        let instant = now()
        return try dbWriter.read { db in
            try Self.selectTrackIds(db, rules: rules, profileId: profileId, now: instant)
        }
    }
}

// MARK: - Off-actor async overloads

public extension SmartPlaylistRepository {
    /// Stores rules on a writer OFF the calling actor.
    @discardableResult
    func setRules(
        _ rules: SmartPlaylistRules,
        forPlaylist playlistId: Int64
    ) async throws -> SmartPlaylistRecord {
        let json = try rules.encodedJSON()
        let version = rules.schemaVersion
        return try await dbWriter.write { db in
            try Self.save(db, json: json, version: version, playlistId: playlistId)
        }
    }

    /// Reads a playlist's rules OFF the calling actor.
    func rules(forPlaylist playlistId: Int64) async throws -> SmartPlaylistRules? {
        try await dbWriter.read { db in try Self.fetchRules(db, playlistId: playlistId) }
    }

    /// Evaluates and materialises on a writer OFF the calling actor.
    @discardableResult
    func evaluate(playlistId: Int64) async throws -> SmartPlaylistEvaluation {
        let instant = now()
        return try await dbWriter.write { db in
            try SmartPlaylistEvaluator.evaluate(db, playlistId: playlistId, now: instant)
        }
    }

    /// Reads staleness OFF the calling actor.
    func isStale(playlistId: Int64, ttl: TimeInterval) async throws -> Bool {
        let instant = now()
        return try await dbWriter.read { db in
            try Self.isStale(db, playlistId: playlistId, ttl: ttl, now: instant)
        }
    }

    /// Previews a rule set's selection on a READER OFF the calling actor.
    ///
    /// `read` rather than `write` is the enforcement, not a preference: this call
    /// physically cannot rewrite `playlistTrack`.
    func previewTrackIds(matching rules: SmartPlaylistRules, profileId: Int64) async throws -> [Int64] {
        let instant = now()
        return try await dbWriter.read { db in
            try Self.selectTrackIds(db, rules: rules, profileId: profileId, now: instant)
        }
    }
}

// MARK: - Shared query bodies (sync + async funnel through these)

private extension SmartPlaylistRepository {
    static func save(
        _ db: Database,
        json: String,
        version: Int,
        playlistId: Int64
    ) throws -> SmartPlaylistRecord {
        if var existing = try SmartPlaylistRecord
            .filter(SmartPlaylistRecord.Columns.playlistId == playlistId)
            .fetchOne(db)
        {
            existing.rulesJson = json
            existing.rulesVersion = version
            existing.lastEvaluatedAt = nil
            try existing.update(db)
            return existing
        }
        var record = SmartPlaylistRecord(playlistId: playlistId, rulesJson: json, rulesVersion: version)
        try record.insert(db)
        return record
    }

    static func fetchRules(_ db: Database, playlistId: Int64) throws -> SmartPlaylistRules? {
        guard let record = try SmartPlaylistRecord
            .filter(SmartPlaylistRecord.Columns.playlistId == playlistId)
            .fetchOne(db)
        else {
            return nil
        }
        return try SmartPlaylistRules.decode(json: record.rulesJson, declaredVersion: record.rulesVersion)
    }

    static func selectTrackIds(
        _ db: Database,
        rules: SmartPlaylistRules,
        profileId: Int64,
        now: Date
    ) throws -> [Int64] {
        let query = try SmartPlaylistCompiler.compile(rules, profileId: profileId, now: now, in: db)
        return try query.request.fetchAll(db)
    }

    static func isStale(_ db: Database, playlistId: Int64, ttl: TimeInterval, now: Date) throws -> Bool {
        guard let record = try SmartPlaylistRecord
            .filter(SmartPlaylistRecord.Columns.playlistId == playlistId)
            .fetchOne(db)
        else {
            throw SmartPlaylistError.rulesNotFound(playlistId: playlistId)
        }
        guard let lastEvaluatedAt = record.lastEvaluatedAt else { return true }
        return now.timeIntervalSince1970 - lastEvaluatedAt >= ttl
    }
}
