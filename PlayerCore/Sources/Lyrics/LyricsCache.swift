import Foundation
import GRDB
import Persistence

// LyricsCache — GRDB-backed persistence for resolved lyrics (migration "v4").
//
// Resolved lyrics are cached so that re-opening a track is instant and so an
// opt-in LRCLIB result is not re-fetched. The payload is the JSON encoding of a
// ``Lyrics`` value, keyed by ``LyricsRequest/cacheKey``.
//
// The table also records **negative** results: a track probed offline and found
// to have no lyrics gets a sentinel row (see ``LyricsCacheSentinel``) so the
// offline sweep never re-opens the same lyricless file on every launch.
//
// Writers race: the offline sweep and the online enrichment pass resolve the same
// track concurrently. Both write paths are therefore ordered rather than
// last-writer-wins — ``LyricsCaching/markNoLyrics(forKey:)`` never overwrites a
// row, and ``LyricsCaching/store(_:forKey:)`` is precedence-monotonic in a single
// transaction and returns whatever document ends up in the row.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// The reserved `lyricsCache.source` value of a **negative-result** row: a track
/// that was probed for lyrics and definitively has none.
///
/// It is deliberately outside ``LyricsSource``'s raw values, so a sentinel can
/// never be mistaken for a real document. Its payload is empty and MUST NOT be
/// handed to `JSONDecoder` — every reader checks the source column first.
public enum LyricsCacheSentinel {
    /// The `source` column value marking a negative probe.
    public static let source = "none"
    /// The (empty) `payloadJson` column value of a sentinel row.
    public static let payload = ""
}

/// Persistence contract for resolved lyrics, keyed by a stable cache key.
public protocol LyricsCaching: Sendable {
    /// Returns the cached lyrics for `key`, or `nil` when absent.
    ///
    /// A negative-result sentinel reads as a **miss** (`nil`), never as an empty
    /// document.
    func load(forKey key: String) throws -> Lyrics?

    /// Upserts `lyrics` under `key` **precedence-monotonically** and returns the
    /// document that is in the row afterwards.
    ///
    /// A sentinel is always overwritten. Real content is overwritten only when
    /// the incoming source's ``LyricsSource/precedenceRank`` is greater than or
    /// equal to the stored one's, so a late offline sweep can never downgrade
    /// synced/LRCLIB lyrics to embedded-unsynced text. When the incoming document
    /// loses, the **stored winner** is returned — the caller that lost the race
    /// still receives what the next reader would see.
    @discardableResult
    func store(_ lyrics: Lyrics, forKey key: String) throws -> Lyrics

    /// Records that `key` was probed and has no lyrics, **without** disturbing an
    /// existing row.
    ///
    /// A sentinel can never overwrite real lyrics: a row already under `key` —
    /// document or sentinel — is left exactly as it is.
    func markNoLyrics(forKey key: String) throws

    /// Removes any cached lyrics (or sentinel) for `key`. No-op when absent.
    func remove(forKey key: String) throws
}

/// A GRDB-backed ``LyricsCaching`` persisting to the `lyricsCache` table.
public struct GRDBLyricsCache: LyricsCaching {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    public init(_ appDatabase: AppDatabase) {
        writer = appDatabase.writer
    }

    public func load(forKey key: String) throws -> Lyrics? {
        try writer.read { db in
            guard let record = try Self.fetch(db, key: key) else { return nil }
            guard record.source != LyricsCacheSentinel.source else { return nil }
            return try Self.decode(record)
        }
    }

    @discardableResult
    public func store(_ lyrics: Lyrics, forKey key: String) throws -> Lyrics {
        try writer.write { db in
            var record = try Self.encode(lyrics, key: key)
            guard let existing = try Self.fetch(db, key: key) else {
                try record.insert(db)
                return lyrics
            }
            if let kept = Self.storedWinner(over: lyrics, existing: existing) {
                return kept
            }
            record.id = existing.id
            try record.update(db)
            return lyrics
        }
    }

    public func markNoLyrics(forKey key: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO lyricsCache (cacheKey, source, payloadJson, fetchedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(cacheKey) DO NOTHING
                """,
                arguments: [
                    key,
                    LyricsCacheSentinel.source,
                    LyricsCacheSentinel.payload,
                    Date().timeIntervalSince1970,
                ]
            )
        }
    }

    /// The stored document that outranks `incoming`, or `nil` when `incoming`
    /// should overwrite the row.
    ///
    /// A sentinel always loses. A real row wins only when its source strictly
    /// outranks the incoming one *and* its payload still decodes — an undecodable
    /// or unknown-source row loses so the cache self-heals.
    private static func storedWinner(over incoming: Lyrics, existing: LyricsCacheRecord) -> Lyrics? {
        guard existing.source != LyricsCacheSentinel.source,
              let storedSource = LyricsSource(rawValue: existing.source),
              storedSource.precedenceRank > incoming.source.precedenceRank,
              let stored = try? decode(existing)
        else { return nil }
        return stored
    }

    private static func fetch(_ db: Database, key: String) throws -> LyricsCacheRecord? {
        try LyricsCacheRecord
            .filter(LyricsCacheRecord.Columns.cacheKey == key)
            .fetchOne(db)
    }

    public func remove(forKey key: String) throws {
        _ = try writer.write { db in
            try LyricsCacheRecord
                .filter(LyricsCacheRecord.Columns.cacheKey == key)
                .deleteAll(db)
        }
    }

    private static func encode(_ lyrics: Lyrics, key: String) throws -> LyricsCacheRecord {
        let data = try JSONEncoder().encode(lyrics)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                lyrics,
                .init(codingPath: [], debugDescription: "lyrics JSON encoding produced non-UTF8 data")
            )
        }
        return LyricsCacheRecord(
            id: nil,
            cacheKey: key,
            source: lyrics.source.rawValue,
            payloadJson: json,
            fetchedAt: Date().timeIntervalSince1970
        )
    }

    private static func decode(_ record: LyricsCacheRecord) throws -> Lyrics {
        guard let data = record.payloadJson.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "payloadJson is not valid UTF-8")
            )
        }
        return try JSONDecoder().decode(Lyrics.self, from: data)
    }
}

/// An in-memory ``LyricsCaching`` for tests and previews, with the same
/// sentinel and precedence-monotonic semantics as ``GRDBLyricsCache``.
public final class FakeLyricsCache: LyricsCaching, @unchecked Sendable {
    private enum Entry {
        case sentinel
        case document(Lyrics)
    }

    private let lock = NSLock()
    private var storage: [String: Entry] = [:]

    public init() {}

    /// `true` when `key` holds a negative-result sentinel rather than a document.
    public func isNegativeSentinel(forKey key: String) -> Bool {
        lock.withLock {
            if case .sentinel = storage[key] { return true }
            return false
        }
    }

    public func load(forKey key: String) throws -> Lyrics? {
        lock.withLock {
            guard case let .document(lyrics) = storage[key] else { return nil }
            return lyrics
        }
    }

    @discardableResult
    public func store(_ lyrics: Lyrics, forKey key: String) throws -> Lyrics {
        lock.withLock {
            if case let .document(stored) = storage[key],
               stored.source.precedenceRank > lyrics.source.precedenceRank
            {
                return stored
            }
            storage[key] = .document(lyrics)
            return lyrics
        }
    }

    public func markNoLyrics(forKey key: String) throws {
        lock.withLock {
            guard storage[key] == nil else { return }
            storage[key] = .sentinel
        }
    }

    public func remove(forKey key: String) throws {
        lock.withLock { storage[key] = nil }
    }
}

/// A GRDB record mapping a cached lyrics payload to the `lyricsCache` table.
struct LyricsCacheRecord: Codable, Equatable {
    var id: Int64?
    var cacheKey: String
    var source: String
    var payloadJson: String
    var fetchedAt: Double?
}

extension LyricsCacheRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "lyricsCache"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let cacheKey = Column(CodingKeys.cacheKey)
        static let source = Column(CodingKeys.source)
        static let payloadJson = Column(CodingKeys.payloadJson)
        static let fetchedAt = Column(CodingKeys.fetchedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
