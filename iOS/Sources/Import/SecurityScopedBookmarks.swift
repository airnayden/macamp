// SecurityScopedBookmarks — persists + resolves security-scoped bookmarks.
//
// A document-picker URL only grants access for the current launch; to re-open the
// same folder/file later the grant must be captured as a security-scoped bookmark
// and stored. This file owns that persistence (the GRDB `bookmark` table, Task 5)
// plus the ``SecurityScopedBookmarkManager`` that mints, resolves and — when the
// system reports a bookmark stale — transparently re-mints + re-saves it. The
// balance + staleness PRIMITIVES it builds on are the pure helpers in
// `BookmarkLifecycle.swift`.
import Foundation
import GRDB
import Persistence

// MARK: - Scope

/// Caller-defined `bookmark.scope` tags. Imports all share one scope so the whole
/// set of granted roots can be re-established together on a later launch.
enum BookmarkScope {
    /// Roots the user added through the library import picker.
    static let libraryImport = "library.import"
}

// MARK: - Platform options

/// Bookmark options differ by platform: macOS must opt into `.withSecurityScope`,
/// whereas an iOS document-picker URL is implicitly security-scoped. Keeping the
/// branch here means the manager reads the same way on both.
enum BookmarkOptions {
    static var creation: URL.BookmarkCreationOptions {
        #if os(macOS)
            [.withSecurityScope]
        #else
            []
        #endif
    }

    static var resolution: URL.BookmarkResolutionOptions {
        #if os(macOS)
            [.withSecurityScope]
        #else
            []
        #endif
    }
}

// MARK: - BookmarkStoring

/// The persistence seam for security-scoped bookmarks. A protocol so the manager
/// is testable against an in-memory double instead of a live database.
protocol BookmarkStoring: Sendable {
    /// The `bookmark.scope` this store reads and writes.
    var scope: String { get }
    /// Upserts bookmark `data` for `resolvedPath` (replacing an existing row for
    /// the same scope + path, else inserting a new one).
    func saveBookmark(_ data: Data, resolvedPath: String?) throws
    /// Every persisted bookmark in this scope.
    func loadBookmarks() throws -> [BookmarkRecord]
    /// Overwrites a known row's blob (used after a stale re-resolve).
    func replaceBookmark(id: Int64, data: Data, resolvedPath: String?) throws
    /// Removes a row that could no longer be resolved.
    func deleteBookmark(id: Int64) throws
}

// MARK: - GRDBBookmarkStore

/// The production ``BookmarkStoring`` backed by the migrated `bookmark` table.
struct GRDBBookmarkStore: BookmarkStoring {
    let database: AppDatabase
    let scope: String

    init(database: AppDatabase, scope: String = BookmarkScope.libraryImport) {
        self.database = database
        self.scope = scope
    }

    func saveBookmark(_ data: Data, resolvedPath: String?) throws {
        try database.writer.write { db in
            if let path = resolvedPath,
               var existing = try BookmarkRecord
               .filter(BookmarkRecord.Columns.scope == scope)
               .filter(BookmarkRecord.Columns.resolvedPath == path)
               .fetchOne(db)
            {
                existing.bookmarkData = data
                try existing.update(db)
            } else {
                var record = BookmarkRecord(scope: scope, bookmarkData: data, resolvedPath: resolvedPath)
                try record.insert(db)
            }
        }
    }

    func loadBookmarks() throws -> [BookmarkRecord] {
        try database.writer.read { db in
            try BookmarkRecord
                .filter(BookmarkRecord.Columns.scope == scope)
                .order(BookmarkRecord.Columns.id)
                .fetchAll(db)
        }
    }

    func replaceBookmark(id: Int64, data: Data, resolvedPath: String?) throws {
        try database.writer.write { db in
            guard var record = try BookmarkRecord.fetchOne(db, key: id) else { return }
            record.bookmarkData = data
            record.resolvedPath = resolvedPath
            try record.update(db)
        }
    }

    func deleteBookmark(id: Int64) throws {
        _ = try database.writer.write { db in
            try BookmarkRecord.deleteOne(db, key: id)
        }
    }
}

// MARK: - InMemoryBookmarkStore (fake)

/// A deterministic ``BookmarkStoring`` double for previews + reasoning: an
/// in-memory array guarded by a lock (the protocol is `Sendable`).
final class InMemoryBookmarkStore: BookmarkStoring, @unchecked Sendable {
    let scope: String
    private let lock = NSLock()
    private var records: [BookmarkRecord] = []
    private var nextID: Int64 = 1

    init(scope: String = BookmarkScope.libraryImport) {
        self.scope = scope
    }

    /// Snapshot of the stored rows (test inspection).
    var stored: [BookmarkRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func saveBookmark(_ data: Data, resolvedPath: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let path = resolvedPath,
           let index = records.firstIndex(where: { $0.resolvedPath == path })
        {
            records[index].bookmarkData = data
        } else {
            records.append(BookmarkRecord(id: nextID, scope: scope, bookmarkData: data, resolvedPath: resolvedPath))
            nextID += 1
        }
    }

    func loadBookmarks() throws -> [BookmarkRecord] {
        stored
    }

    func replaceBookmark(id: Int64, data: Data, resolvedPath: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].bookmarkData = data
        records[index].resolvedPath = resolvedPath
    }

    func deleteBookmark(id: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == id }
    }
}

// MARK: - ResolvedRoot

/// A persisted bookmark resolved back to a live URL, paired with its (possibly
/// refreshed) record.
struct ResolvedRoot: Equatable {
    var url: URL
    var record: BookmarkRecord
}

// MARK: - SecurityScopedBookmarkManager

/// Mints, persists and resolves security-scoped bookmarks, handling staleness.
/// Stateless over a ``BookmarkStoring``, so it is `Sendable` and cheap to build.
struct SecurityScopedBookmarkManager {
    let store: any BookmarkStoring

    /// Mints a security-scoped bookmark for `url` (the caller MUST already hold
    /// scoped access — the import flow starts it before calling) and persists it.
    func persist(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: BookmarkOptions.creation,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try store.saveBookmark(data, resolvedPath: url.path)
    }

    /// Resolves every persisted root, re-minting any whose data is stale. Rows
    /// that no longer resolve are dropped from the result (left for cleanup).
    func resolveRoots() -> [ResolvedRoot] {
        let records = (try? store.loadBookmarks()) ?? []
        return records.compactMap(resolve)
    }

    /// Resolves one record, applying the pure ``bookmarkRefreshPlan(isStale:)``.
    func resolve(_ record: BookmarkRecord) -> ResolvedRoot? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: record.bookmarkData,
            options: BookmarkOptions.resolution,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        switch bookmarkRefreshPlan(isStale: isStale) {
        case .reuse:
            return ResolvedRoot(url: url, record: record)
        case .refreshAndPersist:
            return refreshed(record, resolvedTo: url)
        }
    }

    /// Re-mints + re-persists a stale bookmark from its freshly resolved URL,
    /// holding scoped access only for the mint (balanced by the pure helper).
    private func refreshed(_ record: BookmarkRecord, resolvedTo url: URL) -> ResolvedRoot {
        let data = withSecurityScopedAccess(to: url) { _ in
            try? url.bookmarkData(
                options: BookmarkOptions.creation,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        var updated = record
        updated.resolvedPath = url.path
        if let data, let identifier = record.id {
            try? store.replaceBookmark(id: identifier, data: data, resolvedPath: url.path)
            updated.bookmarkData = data
        }
        return ResolvedRoot(url: url, record: updated)
    }
}
