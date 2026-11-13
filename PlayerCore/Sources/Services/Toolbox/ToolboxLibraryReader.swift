// ToolboxLibraryReader — the production ``ToolboxLibraryReading`` over the
// application database.
//
// ── THE SAMPLER REUSES THE SMART-PLAYLIST COMPILER, UNMODIFIED ────────────────
//
// `sample_tracks` narrows by genre, year, tempo and energy — which is exactly the
// set `SmartPlaylistCompiler` already lowers, with `LibraryVisibility` composed at
// the top level and a mandatory `LIMIT`. Re-deriving that SQL here would create a
// second definition of "the tracks this profile can see" to keep in step with the
// first. So the filter is mapped to a ``SmartPlaylistRules`` value and compiled;
// NOT ONE LINE of the compiler changes, and it is used purely as a reader (no
// `smartPlaylist` row is created and no membership is rewritten).
//
// Two consequences worth stating out loud, both inherited deliberately:
//
//  * An UN-ANALYSED track is never excluded by a tempo or energy bound — the
//    compiler's audio-feature clauses are `(<column> IS NULL OR <range>)`, because
//    analysis is opt-in and may never have run. `sample_tracks`'s description says
//    so, so a model is not surprised by a 90 bpm track in a "fast" sample.
//  * The result is ordered by `(sortTitle, track.id)`, which is deterministic.
//    The "random-ish" part of sampling is a SEEDED shuffle applied afterwards by
//    the tool — see `LibraryToolbox+Sample.swift`.
//
// `.availability = present` is always added: a sample exists to be played, and
// offering a track whose file is missing is offering a dead row.
//
// This file imports Foundation + GRDB + Persistence; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import GRDB
import Persistence

/// Reads the toolbox needs that no repository exposes, over `AppDatabase`.
public struct ToolboxLibraryReader: ToolboxLibraryReading {
    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func audioFeatures(trackIds: [Int64]) async throws -> [Int64: TrackAudioFeatureRecord] {
        let ids = Array(trackIds.prefix(ToolResultBudget.identifierBatchLimit))
        guard !ids.isEmpty else { return [:] }
        return try await dbWriter.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let rows = try TrackAudioFeatureRecord.fetchAll(db, sql: """
            SELECT * FROM trackAudioFeature WHERE trackId IN (\(placeholders))
            """, arguments: StatementArguments(ids))
            var resolved: [Int64: TrackAudioFeatureRecord] = [:]
            resolved.reserveCapacity(rows.count)
            for row in rows {
                resolved[row.trackId] = row
            }
            return resolved
        }
    }

    public func visibleTracks(profileId: Int64, trackIds: [Int64]) async throws -> [Int64: TrackRecord] {
        let ids = Array(Set(trackIds).prefix(ToolResultBudget.identifierBatchLimit))
        guard !ids.isEmpty else { return [:] }
        return try await dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var arguments: [any DatabaseValueConvertible] = ids
            arguments.append(contentsOf: visibility.arguments)
            let rows = try TrackRecord.fetchAll(db, sql: """
            SELECT track.* FROM track
            WHERE track.id IN (\(placeholders)) AND \(visibility.sql)
            """, arguments: StatementArguments(arguments))
            var resolved: [Int64: TrackRecord] = [:]
            resolved.reserveCapacity(rows.count)
            for row in rows {
                guard let trackId = row.id else { continue }
                resolved[trackId] = row
            }
            return resolved
        }
    }

    public func genreCounts(profileId: Int64, limit: Int) async throws -> [ToolboxGenreCount] {
        let pageLimit = max(1, limit)
        return try await dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId)
            var arguments: [any DatabaseValueConvertible] = []
            arguments.append(contentsOf: visibility.arguments)
            arguments.append(pageLimit)
            let rows = try Row.fetchAll(db, sql: """
            SELECT COALESCE(genre, '') AS name, COUNT(*) AS trackCount FROM track
            WHERE \(visibility.sql)
            GROUP BY COALESCE(genre, '')
            ORDER BY trackCount DESC, name COLLATE NOCASE ASC
            LIMIT ?
            """, arguments: StatementArguments(arguments))
            return rows.map { row in
                ToolboxGenreCount(name: row["name"], trackCount: row["trackCount"])
            }
        }
    }

    public func sampleTrackIds(
        profileId: Int64,
        filter: ToolboxSampleFilter,
        limit: Int,
        now: Date
    ) async throws -> [Int64] {
        let rules = Self.rules(for: filter, limit: limit)
        return try await dbWriter.read { db in
            try SmartPlaylistCompiler
                .compile(rules, profileId: profileId, now: now, in: db)
                .request
                .fetchAll(db)
        }
    }
}

// MARK: - Filter lowering

extension ToolboxLibraryReader {
    /// Maps a ``ToolboxSampleFilter`` onto the rule vocabulary the compiler reads.
    ///
    /// A bound-less facet contributes NO predicate rather than an unbounded one:
    /// the compiler would emit a tautology either way, but leaving it out keeps the
    /// generated SQL (and therefore a recorded-plan assertion) minimal.
    static func rules(for filter: ToolboxSampleFilter, limit: Int) -> SmartPlaylistRules {
        var predicates: [SmartPlaylistPredicate] = [.metadata(.availability(equals: .present))]
        if let genre = filter.genre {
            predicates.append(.metadata(.genre(equals: genre)))
        }
        if filter.minimumYear != nil || filter.maximumYear != nil {
            predicates.append(.metadata(.year(
                range: SmartPlaylistRange(lower: filter.minimumYear, upper: filter.maximumYear)
            )))
        }
        if filter.minimumTempo != nil || filter.maximumTempo != nil {
            predicates.append(.audioFeature(.bpm(
                range: SmartPlaylistRange(lower: filter.minimumTempo, upper: filter.maximumTempo)
            )))
        }
        if filter.minimumEnergy != nil || filter.maximumEnergy != nil {
            predicates.append(.audioFeature(.energy(
                range: SmartPlaylistRange(lower: filter.minimumEnergy, upper: filter.maximumEnergy)
            )))
        }
        return SmartPlaylistRules(
            match: .all,
            predicates: predicates,
            sort: SmartPlaylistSort(field: .title, direction: .ascending),
            limit: limit
        )
    }
}
