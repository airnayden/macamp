import Foundation
import GRDB

/// The errors a ``ProfileRepository`` can throw.
public enum ProfileRepositoryError: Error, Sendable, Equatable {
    /// The built-in Guest profile (``ProfileRecord/guestID``) can never be deleted;
    /// it is the ownerless fallback every install ships with.
    case guestUndeletable
}

/// Read/write access to the `profile` table.
///
/// The profile set is intentionally tiny (roughly one per household member), so the
/// listing is `LIMIT`-capped at ``ProfileRepository/fetchLimit`` rather than
/// keyset-paginated — the same bounded-fetch stance the rest of `Persistence` takes,
/// sized for a small table. Every method funnels through the injected
/// `any DatabaseWriter`; a bare `Database` connection is never vended.
///
/// All methods are synchronous. Callers that must not block their actor (e.g. a
/// `@MainActor` view model) wrap them in `Task.detached`, the established pattern in
/// this codebase; a `Fake` conformer for `Services`-layer tests can be added when a
/// downstream task first needs one.
public protocol ProfileRepositoryProviding: Sendable {
    /// Every profile ordered by `id` (Guest, id 1, first), capped at `limit`.
    func allProfiles(limit: Int) throws -> [ProfileRecord]
    /// The profile with `id`, or `nil` if none exists.
    func profile(id: Int64) throws -> ProfileRecord?
    /// Inserts a new profile and returns it with its assigned `id`.
    @discardableResult func create(_ profile: ProfileRecord) throws -> ProfileRecord
    /// Persists changes to an existing profile.
    func update(_ profile: ProfileRecord) throws
    /// Deletes a profile. Throws ``ProfileRepositoryError/guestUndeletable`` for the
    /// Guest profile; otherwise relies on `ON DELETE CASCADE` to drop dependent rows.
    func delete(id: Int64) throws
}

/// The concrete ``ProfileRepositoryProviding`` over a GRDB writer.
///
/// Holds `any DatabaseWriter`; reads use `read { }` (a writer is also a reader),
/// writes use `write { }`. Nothing outside a closure ever touches a raw connection.
public struct ProfileRepository: ProfileRepositoryProviding {
    /// The bounded cap for a full profile listing. Profiles are few; the cap only
    /// exists to honour the "no unbounded fetch" invariant.
    public static let fetchLimit = 256

    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// All profiles ordered by `id` (Guest, id 1, sorts first), capped at `limit`.
    public func allProfiles(limit: Int = ProfileRepository.fetchLimit) throws -> [ProfileRecord] {
        try dbWriter.read { db in
            try ProfileRecord
                .order(ProfileRecord.Columns.id)
                .limit(max(1, limit))
                .fetchAll(db)
        }
    }

    public func profile(id: Int64) throws -> ProfileRecord? {
        try dbWriter.read { db in try ProfileRecord.fetchOne(db, key: id) }
    }

    @discardableResult
    public func create(_ profile: ProfileRecord) throws -> ProfileRecord {
        var copy = profile
        try dbWriter.write { db in try copy.insert(db) }
        return copy
    }

    public func update(_ profile: ProfileRecord) throws {
        try dbWriter.write { db in try profile.update(db) }
    }

    /// Deletes a profile. The built-in Guest profile is undeletable and throws
    /// ``ProfileRepositoryError/guestUndeletable``. For any other profile the delete
    /// relies on `ON DELETE CASCADE` to drop its `profileTrackState`, `playlist` and
    /// `libraryRoot` rows — so foreign keys MUST be enabled on the writer (they are,
    /// by GRDB default and on ``AppDatabase/makeEmpty()``).
    public func delete(id: Int64) throws {
        guard id != ProfileRecord.guestID else {
            throw ProfileRepositoryError.guestUndeletable
        }
        try dbWriter.write { db in _ = try ProfileRecord.deleteOne(db, key: id) }
    }
}
