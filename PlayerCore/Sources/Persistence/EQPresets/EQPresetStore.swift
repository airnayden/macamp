import Foundation
import GRDB

// EQPresetStore — protocol + GRDB-backed implementation for custom EQ preset persistence.
//
// Built-in presets (EQPreset.builtIns) are code constants and are NEVER stored in the
// database. Only user-created custom presets are persisted in the `eqPreset` table.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

// MARK: - Protocol

/// Persistence contract for custom EQ presets.
///
/// Conformers must be `Sendable` so they can be passed across actor boundaries.
public protocol EQPresetStoring: Sendable {
    /// Returns all persisted custom presets, ordered by name.
    func loadAll() throws -> [EQPreset]

    /// Persists a custom preset. If a preset with the same name already exists
    /// it is replaced (upsert semantics).
    func save(_ preset: EQPreset) throws

    /// Deletes the custom preset with the given name. No-op if not found.
    func delete(named name: String) throws

    /// Exports all custom presets as a JSON-encoded `Data` blob.
    func exportJSON() throws -> Data

    /// Imports presets from a JSON-encoded `Data` blob produced by `exportJSON()`.
    /// Existing presets with the same name are replaced.
    func importJSON(_ data: Data) throws
}

// MARK: - GRDB implementation

/// A GRDB-backed `EQPresetStoring` that persists custom presets in the `eqPreset` table.
public struct GRDBEQPresetStore: EQPresetStoring {
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

    public func loadAll() throws -> [EQPreset] {
        try writer.read { db in
            let records = try EQPresetRecord
                .order(EQPresetRecord.Columns.name)
                .fetchAll(db)
            return try records.map { try $0.toPreset() }
        }
    }

    public func save(_ preset: EQPreset) throws {
        var record = try EQPresetRecord(preset: preset)
        try writer.write { db in
            if let existing = try EQPresetRecord
                .filter(EQPresetRecord.Columns.name == preset.name)
                .fetchOne(db)
            {
                record.id = existing.id
            }
            try record.save(db)
        }
    }

    public func delete(named name: String) throws {
        _ = try writer.write { db in
            try EQPresetRecord
                .filter(EQPresetRecord.Columns.name == name)
                .deleteAll(db)
        }
    }

    public func exportJSON() throws -> Data {
        let presets = try loadAll()
        return try JSONEncoder().encode(presets)
    }

    public func importJSON(_ data: Data) throws {
        let presets = try JSONDecoder().decode([EQPreset].self, from: data)
        try writer.write { db in
            for preset in presets {
                var record = try EQPresetRecord(preset: preset)
                if let existing = try EQPresetRecord
                    .filter(EQPresetRecord.Columns.name == preset.name)
                    .fetchOne(db)
                {
                    record.id = existing.id
                }
                try record.save(db)
            }
        }
    }
}

// MARK: - Fake (in-memory, test double)

/// An in-memory `EQPresetStoring` for use in tests and previews.
///
/// Thread-safety: protected by a simple `NSLock` so it can be used from
/// multiple threads in parallel test suites.
public final class FakeEQPresetStore: EQPresetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: EQPreset] = [:]

    public init(presets: [EQPreset] = []) {
        for preset in presets {
            storage[preset.name] = preset
        }
    }

    public func loadAll() throws -> [EQPreset] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.name < $1.name }
    }

    public func save(_ preset: EQPreset) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[preset.name] = preset
    }

    public func delete(named name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: name)
    }

    public func exportJSON() throws -> Data {
        let presets = try loadAll()
        return try JSONEncoder().encode(presets)
    }

    public func importJSON(_ data: Data) throws {
        let presets = try JSONDecoder().decode([EQPreset].self, from: data)
        lock.lock()
        defer { lock.unlock() }
        for preset in presets {
            storage[preset.name] = preset
        }
    }
}
