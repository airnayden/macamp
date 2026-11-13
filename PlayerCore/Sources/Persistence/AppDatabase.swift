import Foundation
import GRDB

/// The application database.
///
/// `AppDatabase` is a thin, dependency-injectable wrapper around a GRDB
/// ``DatabaseWriter``. It deliberately exposes the writer as the *protocol*
/// type `any DatabaseWriter` (never a concrete `DatabasePool` / `DatabaseQueue`)
/// so that:
///
/// * production code uses an on-disk ``GRDB/DatabasePool`` in WAL mode
///   (``shared``), enabling concurrent reads while a single writer runs; and
/// * tests inject a fast, isolated in-memory ``GRDB/DatabaseQueue``
///   (``makeEmpty()``).
///
/// All database access goes through `writer.read { db in … }` /
/// `writer.write { db in … }` closures. A bare `Database` connection is never
/// vended to callers outside those closures.
public struct AppDatabase: Sendable {
    /// The underlying GRDB writer.
    ///
    /// Exposed as a protocol existential so callers (and tests) are agnostic to
    /// whether they are talking to a `DatabasePool` or a `DatabaseQueue`.
    public let writer: any DatabaseWriter

    /// Creates an `AppDatabase` on top of an arbitrary writer and brings its
    /// schema up to the latest version with the canonical, non-erasing migrator.
    ///
    /// - Parameter writer: A `DatabasePool` (production) or `DatabaseQueue`
    ///   (tests / previews).
    /// - Throws: Any error raised while running the migrations.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Creates an empty, fully-migrated, in-memory database.
    ///
    /// Each call returns an independent database that lives only for as long as
    /// it is referenced — ideal for unit tests and SwiftUI previews.
    public static func makeEmpty() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }
}

// MARK: - The shared, on-disk database

extension AppDatabase {
    /// The shared, on-disk application database (a WAL-mode `DatabasePool`).
    ///
    /// Lazily created on first access and migrated to the latest schema version.
    /// Because it is an immutable `static let` of a `Sendable` type it is safe
    /// to access from any isolation domain under Swift 6 strict concurrency.
    public static let shared = makeShared()

    /// Builds the production `DatabasePool`.
    ///
    /// The database file lives at
    /// `Application Support/MacAMP/library.sqlite`. Foreign-key enforcement is
    /// on by default (GRDB `Configuration.foreignKeysEnabled == true`).
    private static func makeShared() -> AppDatabase {
        do {
            let folderURL = try FileManager.default
                .url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("MacAMP", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
            let dbURL = folderURL.appendingPathComponent("library.sqlite")

            var config = Configuration()
            // WAL is the DatabasePool default, but we set it explicitly to make
            // the on-disk concurrency model unambiguous at the call site.
            config.journalMode = .wal

            let pool = try DatabasePool(path: dbURL.path, configuration: config)

            return try AppDatabase(pool)
        } catch {
            // A failure here means the app cannot persist anything; there is no
            // reasonable recovery, so we trap rather than vend a broken handle.
            fatalError("Unresolved AppDatabase error: \(error)")
        }
    }
}
