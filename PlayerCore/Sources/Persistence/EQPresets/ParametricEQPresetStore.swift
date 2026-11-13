import Foundation
import GRDB

// ParametricEQPresetStore — protocol + GRDB-backed implementation for custom
// parametric-EQ preset persistence (the v19 `parametricEQPreset` table).
//
// The graphic-EQ store (`EQPresetStoring` / `GRDBEQPresetStore`, v3 `eqPreset`) is a
// separate seam over a separate table and is untouched by this file. There are no
// built-in parametric presets: a bank comes from an AutoEq profile or the editor, so
// every row here is user-authored.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

// MARK: - Protocol

/// Persistence contract for custom parametric-EQ presets.
///
/// Conformers must be `Sendable` so they can be passed across actor boundaries.
public protocol ParametricEQPresetStoring: Sendable {
    /// Returns all persisted presets, ordered by name.
    ///
    /// Never decodes ``ParametricEQPreset/filtersJson``, so a row holding unreadable
    /// JSON is returned alongside its siblings rather than failing the whole read.
    func loadAll() throws -> [ParametricEQPreset]

    /// Persists a preset. A preset with the same name is replaced (upsert semantics),
    /// which the table's `UNIQUE(name)` constraint also enforces from below.
    func save(_ preset: ParametricEQPreset) throws

    /// Deletes the preset with the given name. No-op if not found.
    func delete(named name: String) throws
}

// MARK: - GRDB implementation

/// A GRDB-backed `ParametricEQPresetStoring` over the `parametricEQPreset` table.
public struct GRDBParametricEQPresetStore: ParametricEQPresetStoring {
    private let writer: any DatabaseWriter

    /// Creates a store backed by the given GRDB writer.
    ///
    /// - Parameter writer: A `DatabasePool` (production) or `DatabaseQueue` (tests).
    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Convenience initialiser that unwraps the writer from an `AppDatabase`.
    public init(_ appDatabase: AppDatabase) {
        writer = appDatabase.writer
    }

    public func loadAll() throws -> [ParametricEQPreset] {
        try writer.read { db in
            try ParametricEQPresetRecord
                .order(ParametricEQPresetRecord.Columns.name)
                .fetchAll(db)
                .map { $0.toPreset() }
        }
    }

    public func save(_ preset: ParametricEQPreset) throws {
        var record = ParametricEQPresetRecord(preset: preset)
        try writer.write { db in
            if let existing = try ParametricEQPresetRecord
                .filter(ParametricEQPresetRecord.Columns.name == preset.name)
                .fetchOne(db)
            {
                record.id = existing.id
            }
            try record.save(db)
        }
    }

    public func delete(named name: String) throws {
        _ = try writer.write { db in
            try ParametricEQPresetRecord
                .filter(ParametricEQPresetRecord.Columns.name == name)
                .deleteAll(db)
        }
    }
}

// MARK: - Fake (in-memory, test double)

/// An in-memory `ParametricEQPresetStoring` for use in tests and previews.
///
/// Thread-safety: protected by a simple `NSLock` so it can be used from multiple
/// threads in parallel test suites.
public final class FakeParametricEQPresetStore: ParametricEQPresetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ParametricEQPreset] = [:]

    public init(presets: [ParametricEQPreset] = []) {
        for preset in presets {
            storage[preset.name] = preset
        }
    }

    public func loadAll() throws -> [ParametricEQPreset] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.name < $1.name }
    }

    public func save(_ preset: ParametricEQPreset) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[preset.name] = preset
    }

    public func delete(named name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: name)
    }
}
