import Foundation
import GRDB
import Persistence

// EnrichmentCoverage — the profile-scoped "how enriched is this library, really?"
// aggregate behind the enrichment status surface.
//
// It answers four questions about the tracks the active profile can actually see:
// how many are present, how many have real lyrics, how many were probed and found
// to have none, and how many still lack core metadata. Those numbers exist so the
// UI can say something TRUE instead of "enrichment finished" — a pass that probed
// every track and found nothing is not the same as a fully-enriched library.
//
// It lives in `Lyrics` rather than `Persistence` for the same reason
// ``LyricsBrowseRepository`` does: the counts turn on
// ``LyricsCacheSentinel/source``, and `Persistence` cannot import `Lyrics` (that
// is the dependency direction). Hosting the query here keeps the sentinel's
// meaning defined once.
//
// The query is READ-ONLY: it never resolves, fetches, or writes lyrics, and it
// never changes which tracks ``EnrichmentService`` picks as candidates.
//
// `infoCache` coverage is deliberately OUT of scope: its cache key is derived
// privately inside `InfoService` from the (mutable) title/artist pair, so a SQL
// join against it here would silently disagree with the service. Recorded
// decision — do not add it.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// How much of one profile's visible library has actually been enriched.
///
/// Every member counts **present** tracks only — a `missing` or `externalOffline`
/// row is not a coverage gap, it is an unreachable file — and every member is
/// scoped by ``LibraryVisibility``, so two profiles with disjoint roots report on
/// disjoint libraries.
public struct EnrichmentCoverageCounts: Sendable, Equatable {
    /// Present tracks visible to the profile. The denominator for the other three.
    public let presentTracks: Int
    /// Present tracks holding a real cached lyrics document (never a sentinel).
    public let tracksWithLyrics: Int
    /// Present tracks probed for lyrics that came back empty — a
    /// ``LyricsCacheSentinel`` row. These are *done*, not pending.
    public let tracksProbedNoLyrics: Int
    /// Present tracks still missing at least one core tag (title, artist, album,
    /// genre or year).
    public let tracksMissingCoreMetadata: Int

    public init(
        presentTracks: Int = 0,
        tracksWithLyrics: Int = 0,
        tracksProbedNoLyrics: Int = 0,
        tracksMissingCoreMetadata: Int = 0
    ) {
        self.presentTracks = presentTracks
        self.tracksWithLyrics = tracksWithLyrics
        self.tracksProbedNoLyrics = tracksProbedNoLyrics
        self.tracksMissingCoreMetadata = tracksMissingCoreMetadata
    }

    /// The all-zero reading — an empty (or entirely invisible) library.
    public static let empty = EnrichmentCoverageCounts()
}

/// The bounded read seam the enrichment status surface asks for its numbers.
///
/// One call, one aggregate — never a row fetch, never a page. Profile-scoped like
/// every sibling library query.
public protocol EnrichmentCoverageReading: Sendable {
    /// The coverage counts for the tracks visible to `profileId`.
    func counts(profileId: Int64) throws -> EnrichmentCoverageCounts
}

/// The GRDB-backed ``EnrichmentCoverageReading`` over the `track` ⋈ `lyricsCache`
/// anti-join, evaluated in a single read transaction.
public struct EnrichmentCoverageReader: EnrichmentCoverageReading {
    private let reader: any DatabaseReader

    public init(_ reader: any DatabaseReader) {
        self.reader = reader
    }

    public init(_ appDatabase: AppDatabase) {
        reader = appDatabase.writer
    }

    public func counts(profileId: Int64 = ProfileRecord.guestID) throws -> EnrichmentCoverageCounts {
        try reader.read { db in
            let query = try enrichmentCoverageQuery(db, profileId: profileId)
            let row = try Row.fetchOne(db, sql: query.sql, arguments: StatementArguments(query.arguments))
            guard let row else { return .empty }
            return decodeEnrichmentCoverage(row)
        }
    }
}

/// A track is missing core metadata when any of its four display tags is blank or
/// it has no release year.
///
/// "Blank" is `IS NULL OR = ''` — the same SQL-side test
/// ``TrackRepository``'s untagged-genre filter uses, so "untagged" means one thing
/// across the library. It is marginally narrower than
/// `EnrichmentService.isBlank` (which also trims whitespace), so a tag of pure
/// whitespace reads as present here; that is an import artefact rare enough not to
/// justify a custom SQL function.
///
/// This set is intentionally a SUBSET of `EnrichmentService.needsMetadata`, which
/// additionally requires `albumArtist` and `trackNumber`. These are the tags a
/// user recognises as "my library is tagged"; the service's candidate selection is
/// not changed by, and must not be derived from, this predicate.
private let missingCoreMetadataSQL = """
(track.title IS NULL OR track.title = ''
       OR track.artistName IS NULL OR track.artistName = ''
       OR track.albumTitle IS NULL OR track.albumTitle = ''
       OR track.genre IS NULL OR track.genre = ''
       OR track.year IS NULL)
"""

/// The one-pass coverage aggregate and its bound arguments in placeholder order.
///
/// The `LEFT JOIN` is the anti-join: `lyricsCache.cacheKey` is `UNIQUE`, so at
/// most one row can match a track and the join cannot multiply rows (the same
/// guarantee ``LyricsBrowseRepository`` relies on, and the shape
/// `TrackRepository.filePathsWithoutLyricsProbe` already uses on this exact key).
/// One join probe per track answers BOTH lyrics questions; a pair of correlated
/// `EXISTS` subqueries would cost two or three index seeks per row for the same
/// answer.
///
/// Uniqueness is also why `tracksProbedNoLyrics` needs no "and no real row exists"
/// clause: a sentinel row and a real row cannot coexist under one `cacheKey`.
/// `lc.source` is `NOT NULL`, so `lc.source IS NOT NULL` is exactly "a cache row
/// matched"; with no match every `CASE` falls through to `0`.
///
/// `COALESCE` wraps each `SUM` because `SUM` over zero rows is `NULL`, and an
/// empty library must report zeros rather than fail to decode.
///
/// Internal (not `private`) so `EnrichmentCoverageTests` can run
/// `EXPLAIN QUERY PLAN` over the exact statement production runs, arguments
/// included — the discipline `FolderTreeQueryPlanTests` established.
func enrichmentCoverageQuery(
    _ db: Database,
    profileId: Int64
) throws -> (sql: String, arguments: [any DatabaseValueConvertible]) {
    let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
    let sql = """
    SELECT
      COUNT(*) AS presentTracks,
      COALESCE(SUM(CASE WHEN lc.source IS NOT NULL AND lc.source <> ? THEN 1 ELSE 0 END), 0) AS tracksWithLyrics,
      COALESCE(SUM(CASE WHEN lc.source = ? THEN 1 ELSE 0 END), 0) AS tracksProbedNoLyrics,
      COALESCE(SUM(CASE WHEN \(missingCoreMetadataSQL) THEN 1 ELSE 0 END), 0) AS tracksMissingCoreMetadata
    FROM track
    LEFT JOIN lyricsCache lc ON lc.cacheKey = track.filePath
    WHERE track.availability = ?
      AND \(visibility.sql)
    """
    var arguments: [any DatabaseValueConvertible] = [
        LyricsCacheSentinel.source,
        LyricsCacheSentinel.source,
        Availability.present.rawValue,
    ]
    arguments.append(contentsOf: visibility.arguments)
    return (sql, arguments)
}

private func decodeEnrichmentCoverage(_ row: Row) -> EnrichmentCoverageCounts {
    EnrichmentCoverageCounts(
        presentTracks: row["presentTracks"],
        tracksWithLyrics: row["tracksWithLyrics"],
        tracksProbedNoLyrics: row["tracksProbedNoLyrics"],
        tracksMissingCoreMetadata: row["tracksMissingCoreMetadata"]
    )
}
