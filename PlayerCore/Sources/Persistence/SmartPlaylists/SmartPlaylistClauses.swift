import Foundation
import GRDB

/// One boolean SQL fragment plus the values its `?` placeholders bind.
///
/// The same shape as ``LibraryVisibility/Predicate``, kept separate because these are
/// composed many-to-one before they meet it.
struct SmartPlaylistClause {
    let sql: String
    let arguments: [any DatabaseValueConvertible]

    /// The tautology's SQL. A `let` on the fragment itself cannot be `static`:
    /// `[any DatabaseValueConvertible]` is not `Sendable`, so the type is not either.
    static let unconstrainedSQL = "1"

    /// A predicate that constrains nothing.
    static var unconstrained: SmartPlaylistClause {
        SmartPlaylistClause(sql: unconstrainedSQL, arguments: [])
    }

    var isUnconstrained: Bool {
        sql == SmartPlaylistClause.unconstrainedSQL
    }
}

// MARK: - Predicate lowering

extension SmartPlaylistCompiler {
    /// Routes a predicate to the group that owns its data source.
    static func clause(
        for predicate: SmartPlaylistPredicate,
        profileId: Int64,
        now: Date
    ) -> SmartPlaylistClause {
        switch predicate {
        case let .metadata(metadata): clause(for: metadata)
        case let .profileStat(stat): clause(for: stat)
        case let .recency(recency): clause(for: recency, profileId: profileId, now: now)
        case let .audioFeature(feature): clause(for: feature)
        }
    }

    /// `track` columns. A `NULL` column fails every comparison, so an untagged track
    /// is excluded — which is the intended reading of "year is 1990–1999".
    static func clause(for predicate: SmartPlaylistMetadataPredicate) -> SmartPlaylistClause {
        switch predicate {
        case let .genre(value): textClause("track.genre", value)
        case let .artistName(value): textClause("track.artistName", value)
        case let .albumTitle(value): textClause("track.albumTitle", value)
        case let .year(range): rangeClause("track.year", range)
        case let .duration(range): rangeClause("track.duration", range)
        case let .dateAdded(range): rangeClause("track.dateAdded", range)
        case let .availability(value):
            SmartPlaylistClause(sql: "(track.availability = ?)", arguments: [value.rawValue])
        }
    }

    /// `profileTrackState` columns, read through the compiler's `LEFT JOIN`.
    ///
    /// The table is sparse — a row exists only once the profile has favourited,
    /// played or reordered the track — so an absent row reads as `0` / `false` rather
    /// than dropping the track out of the result.
    static func clause(for predicate: SmartPlaylistProfileStatPredicate) -> SmartPlaylistClause {
        switch predicate {
        case let .playCount(range): rangeClause("COALESCE(\(stateAlias).playCount, 0)", range)
        case let .listenedCount(range): rangeClause("COALESCE(\(stateAlias).listenedCount, 0)", range)
        case let .isFavourite(value):
            SmartPlaylistClause(
                sql: "(COALESCE(\(stateAlias).isFavourite, 0) = ?)",
                arguments: [value]
            )
        }
    }

    /// `playEvent` recency, as a correlated `EXISTS` scoped to this profile.
    ///
    /// A sub-query rather than a join: the question is existential, and the
    /// `(profileId, trackId)` index answers it without multiplying rows.
    static func clause(
        for predicate: SmartPlaylistRecencyPredicate,
        profileId: Int64,
        now: Date
    ) -> SmartPlaylistClause {
        switch predicate {
        case let .playedWithin(days):
            playedClause(negated: false, profileId: profileId, since: cutoff(from: now, days: days))
        case let .notPlayedWithin(days):
            playedClause(negated: true, profileId: profileId, since: cutoff(from: now, days: days))
        }
    }

    /// `trackAudioFeature` columns, each guarded by `IS NULL`.
    ///
    /// Audio analysis is opt-in and may never have run: a feature predicate must
    /// never exclude an un-analysed track, so an absent (or `NULL`) measurement
    /// satisfies the clause.
    static func clause(for predicate: SmartPlaylistAudioFeaturePredicate) -> SmartPlaylistClause {
        switch predicate {
        case let .bpm(range): featureClause("\(featureAlias).bpm", range)
        case let .energy(range): featureClause("\(featureAlias).energy", range)
        case let .brightness(range): featureClause("\(featureAlias).brightness", range)
        }
    }
}

// MARK: - Clause builders

extension SmartPlaylistCompiler {
    /// Exact, case-insensitive text match — the `tracksByGenre` convention.
    static func textClause(_ column: String, _ value: String) -> SmartPlaylistClause {
        SmartPlaylistClause(sql: "(\(column) = ? COLLATE NOCASE)", arguments: [value])
    }

    /// An inclusive window; either bound may be absent, and both absent constrains
    /// nothing.
    static func rangeClause(
        _ column: String,
        _ range: SmartPlaylistRange<some DatabaseValueConvertible & Codable & Sendable & Equatable & Hashable>
    ) -> SmartPlaylistClause {
        switch (range.lower, range.upper) {
        case let (lower?, upper?):
            SmartPlaylistClause(sql: "(\(column) BETWEEN ? AND ?)", arguments: [lower, upper])
        case let (lower?, nil):
            SmartPlaylistClause(sql: "(\(column) >= ?)", arguments: [lower])
        case let (nil, upper?):
            SmartPlaylistClause(sql: "(\(column) <= ?)", arguments: [upper])
        case (nil, nil):
            .unconstrained
        }
    }

    /// ``rangeClause(_:_:)`` widened with an `IS NULL` arm, so a missing measurement
    /// is a no-op rather than an exclusion.
    static func featureClause(
        _ column: String,
        _ range: SmartPlaylistRange<some DatabaseValueConvertible & Codable & Sendable & Equatable & Hashable>
    ) -> SmartPlaylistClause {
        let bounded = rangeClause(column, range)
        guard !bounded.isUnconstrained else { return bounded }
        return SmartPlaylistClause(
            sql: "(\(column) IS NULL OR \(bounded.sql))",
            arguments: bounded.arguments
        )
    }

    static func playedClause(negated: Bool, profileId: Int64, since: Double) -> SmartPlaylistClause {
        let exists = """
        EXISTS (SELECT 1 FROM playEvent WHERE playEvent.profileId = ? \
        AND playEvent.trackId = track.id AND playEvent.startedAt >= ?)
        """
        return SmartPlaylistClause(
            sql: negated ? "(NOT \(exists))" : "(\(exists))",
            arguments: [profileId, since]
        )
    }

    /// `now` minus `days` whole days, as epoch seconds — the form `playEvent.startedAt`
    /// is stored in. A negative `days` is clamped to zero (the window is "the last N
    /// days", never the future).
    static func cutoff(from now: Date, days: Int) -> Double {
        now.timeIntervalSince1970 - Double(max(0, days)) * 86400
    }
}
