import Foundation
import GRDB

/// Persists the one-shot "legacy library roots have already been migrated" flag.
///
/// ``LibraryRootRepository/importLegacyRootsIfNeeded(from:flagStore:)`` reads and
/// sets this flag but never learns its backing store. The shell wires a
/// `UserDefaults`-backed conformer (a later task); keeping the concrete store OUT of
/// `Persistence` preserves the invariant that repositories never touch
/// `UserDefaults`. The **flag** — not a "Guest currently has no roots" heuristic — is
/// what makes the import one-shot, so a user who deletes every Guest root is not
/// handed them back on the next launch.
public protocol LegacyRootsImportFlagStore: Sendable {
    /// Whether the legacy import has already run.
    var legacyRootsImported: Bool { get }
    /// Records that the legacy import has run. Must persist across launches.
    func markLegacyRootsImported()
}

/// Read/write access to the `libraryRoot` table (per-profile library folders).
///
/// A profile's root set is small and bounded, so reads are `LIMIT`-capped at
/// ``LibraryRootRepository/fetchLimit``. Every method funnels through the injected
/// `any DatabaseWriter`; a bare `Database` connection is never vended.
///
/// All methods are synchronous. Callers that must not block their actor wrap them in
/// `Task.detached`, the established pattern in this codebase.
public protocol LibraryRootRepositoryProviding: Sendable {
    /// A profile's library roots ordered by `path`, capped at `limit`.
    func rootsForProfile(_ profileId: Int64, limit: Int) throws -> [LibraryRootRecord]
    /// Adds a library root for a profile and returns it with its assigned `id`.
    @discardableResult func addRoot(profileId: Int64, path: String) throws -> LibraryRootRecord
    /// Removes a root by `id`. Returns whether a row was deleted.
    @discardableResult func removeRoot(id: Int64) throws -> Bool
    /// One-time migration of legacy roots onto Guest, guarded by `flagStore`.
    func importLegacyRootsIfNeeded(from paths: [String], flagStore: LegacyRootsImportFlagStore) throws
}

/// The concrete ``LibraryRootRepositoryProviding`` over a GRDB writer.
public struct LibraryRootRepository: LibraryRootRepositoryProviding {
    /// The bounded cap for a per-profile root listing.
    public static let fetchLimit = 512

    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// A profile's library roots ordered by `path`, capped at `limit`.
    public func rootsForProfile(
        _ profileId: Int64,
        limit: Int = LibraryRootRepository.fetchLimit
    ) throws -> [LibraryRootRecord] {
        try dbWriter.read { db in
            try LibraryRootRecord
                .filter(LibraryRootRecord.Columns.profileId == profileId)
                .order(LibraryRootRecord.Columns.path)
                .limit(max(1, limit))
                .fetchAll(db)
        }
    }

    /// Adds a library root for a profile. Throws on a duplicate `(profileId, path)`
    /// (the table's `UNIQUE` constraint); callers that may re-add should catch it.
    @discardableResult
    public func addRoot(profileId: Int64, path: String) throws -> LibraryRootRecord {
        var record = LibraryRootRecord(profileId: profileId, path: path)
        try dbWriter.write { db in try record.insert(db) }
        return record
    }

    /// Removes a root by `id`. Returns whether a row was deleted.
    @discardableResult
    public func removeRoot(id: Int64) throws -> Bool {
        try dbWriter.write { db in try LibraryRootRecord.deleteOne(db, key: id) }
    }

    /// One-time migration of legacy (pre-profiles) library roots onto the Guest
    /// profile, guarded by the persisted `flagStore` flag so it runs exactly once —
    /// never resurrecting roots a user later deletes.
    ///
    /// `paths` is supplied by the caller (read from `UserDefaults` OUTSIDE
    /// `Persistence`, per the layering invariant); duplicates in `paths` and roots
    /// Guest already owns are skipped via `INSERT OR IGNORE`, which the
    /// `UNIQUE(profileId, path)` constraint drives. The flag is marked even when
    /// `paths` is empty, so a fresh install never retries the migration.
    public func importLegacyRootsIfNeeded(
        from paths: [String],
        flagStore: LegacyRootsImportFlagStore
    ) throws {
        guard !flagStore.legacyRootsImported else { return }
        try dbWriter.write { db in
            for path in paths {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO libraryRoot (profileId, path) VALUES (?, ?)",
                    arguments: [ProfileRecord.guestID, path]
                )
            }
        }
        flagStore.markLegacyRootsImported()
    }
}
