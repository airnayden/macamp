import Foundation
import GRDB
@testable import Lyrics
import Persistence
import Testing

@Suite("EnrichmentCoverageTests")
struct EnrichmentCoverageTests {
    private struct Harness {
        let database: AppDatabase
        let tracks: TrackRepository
        let profiles: ProfileRepository
        let roots: LibraryRootRepository
        let cache: GRDBLyricsCache
        let coverage: EnrichmentCoverageReader
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.makeEmpty()
        return Harness(
            database: database,
            tracks: TrackRepository(database),
            profiles: ProfileRepository(database),
            roots: LibraryRootRepository(database),
            cache: GRDBLyricsCache(database),
            coverage: EnrichmentCoverageReader(database)
        )
    }

    /// Seeds a fully-tagged present track — every core tag the coverage predicate
    /// inspects is filled, so the row is a clean "enriched" baseline that the
    /// per-test overrides can spoil one field at a time.
    @discardableResult
    private func seedTrack(
        _ harness: Harness,
        path: String,
        title: String? = "Title",
        artist: String? = "Artist",
        album: String? = "Album",
        genre: String? = "Rock",
        year: Int? = 1999,
        availability: Availability = .present
    ) throws -> Int64 {
        let record = try harness.tracks.insert(TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title?.lowercased(),
            artistName: artist,
            albumTitle: album,
            availability: availability,
            genre: genre,
            year: year
        ))
        return try #require(record.id)
    }

    private func plainLyrics() -> Lyrics {
        Lyrics(lines: [LyricLine(text: "one"), LyricLine(text: "two")], source: .embeddedUnsynced)
    }

    /// Writes a negative-probe row the way the offline sweep does: `source = "none"`
    /// with an empty payload. `LyricsSource` has no such case, so it cannot be
    /// produced through `GRDBLyricsCache.store`.
    private func seedSentinel(_ harness: Harness, forKey key: String) throws {
        try harness.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO lyricsCache (cacheKey, source, payloadJson, fetchedAt) VALUES (?, ?, ?, ?)",
                arguments: [key, LyricsCacheSentinel.source, LyricsCacheSentinel.payload, 0.0]
            )
        }
    }

    // MARK: - Acceptance

    @Test("the four counts partition a mixed library exactly")
    func countsMixedLibrary() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/lyrics-a.flac", title: "Lyrics A")
        try seedTrack(harness, path: "/M/lyrics-b.flac", title: "Lyrics B")
        try seedTrack(harness, path: "/M/probed.flac", title: "Probed")
        try seedTrack(harness, path: "/M/untouched.flac", title: "Untouched")
        try seedTrack(harness, path: "/M/gone.flac", title: "Gone", availability: .missing)
        try seedTrack(harness, path: "/M/no-genre.flac", title: "No Genre", genre: nil)
        try seedTrack(harness, path: "/M/no-year.flac", title: "No Year", year: nil)

        try harness.cache.store(plainLyrics(), forKey: "/M/lyrics-a.flac")
        try harness.cache.store(plainLyrics(), forKey: "/M/lyrics-b.flac")
        try harness.cache.store(plainLyrics(), forKey: "/M/gone.flac")
        try seedSentinel(harness, forKey: "/M/probed.flac")

        let counts = try harness.coverage.counts()

        #expect(counts == EnrichmentCoverageCounts(
            presentTracks: 6,
            tracksWithLyrics: 2,
            tracksProbedNoLyrics: 1,
            tracksMissingCoreMetadata: 2
        ))
    }

    @Test("a sentinel replaced by a real document counts as enriched, not probed")
    func realLyricsSupersedeSentinel() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/late.flac", title: "Late")
        try seedSentinel(harness, forKey: "/M/late.flac")

        let probed = try harness.coverage.counts()
        try harness.cache.store(plainLyrics(), forKey: "/M/late.flac")
        let resolved = try harness.coverage.counts()

        #expect(probed.tracksProbedNoLyrics == 1)
        #expect(probed.tracksWithLyrics == 0)
        #expect(resolved.tracksProbedNoLyrics == 0)
        #expect(resolved.tracksWithLyrics == 1)
    }

    @Test("an empty tag counts as missing exactly like a NULL one")
    func emptyStringTagsCountAsMissing() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/blank-artist.flac", title: "Blank Artist", artist: "")
        try seedTrack(harness, path: "/M/null-artist.flac", title: "Null Artist", artist: nil)
        try seedTrack(harness, path: "/M/blank-album.flac", title: "Blank Album", album: "")
        try seedTrack(harness, path: "/M/blank-title.flac", title: "")
        try seedTrack(harness, path: "/M/complete.flac", title: "Complete")

        let counts = try harness.coverage.counts()

        #expect(counts.presentTracks == 5)
        #expect(counts.tracksMissingCoreMetadata == 4)
    }

    // MARK: - Profile scoping

    @Test("two profiles with disjoint roots count only their own tracks")
    func profilesWithDisjointRootsAreIsolated() throws {
        let harness = try makeHarness()
        let alex = try #require(try harness.profiles.create(ProfileRecord(name: "Alex")).id)
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness, path: "/Music/Alex/a.flac", title: "Alpha")
        try seedTrack(harness, path: "/Music/Guest/g.flac", title: "Gamma", genre: nil)
        try seedTrack(harness, path: "/Loose/loose.flac", title: "Loose")
        try harness.cache.store(plainLyrics(), forKey: "/Music/Alex/a.flac")
        try seedSentinel(harness, forKey: "/Music/Guest/g.flac")

        let alexCounts = try harness.coverage.counts(profileId: alex)
        let guestCounts = try harness.coverage.counts(profileId: ProfileRecord.guestID)

        #expect(alexCounts == EnrichmentCoverageCounts(
            presentTracks: 2,
            tracksWithLyrics: 1,
            tracksProbedNoLyrics: 0,
            tracksMissingCoreMetadata: 0
        ))
        #expect(guestCounts == EnrichmentCoverageCounts(
            presentTracks: 2,
            tracksWithLyrics: 0,
            tracksProbedNoLyrics: 1,
            tracksMissingCoreMetadata: 1
        ))
    }

    @Test("an empty library reports all zeros without throwing")
    func emptyLibraryIsWellFormed() throws {
        let harness = try makeHarness()

        try #expect(harness.coverage.counts() == .empty)
    }

    // MARK: - Query plan

    @Test("the lyricsCache probe seeks the unique cacheKey index instead of scanning")
    func lyricsCacheProbeIsSargable() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/one.flac", title: "One")
        try seedTrack(harness, path: "/M/two.flac", title: "Two")
        try harness.cache.store(plainLyrics(), forKey: "/M/one.flac")
        try seedSentinel(harness, forKey: "/M/two.flac")

        let details = try harness.database.writer.read { db -> [String] in
            let query = try enrichmentCoverageQuery(db, profileId: ProfileRecord.guestID)
            return try Row
                .fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN \(query.sql)",
                    arguments: StatementArguments(query.arguments)
                )
                .map { row -> String in row["detail"] }
        }

        print("enrichmentCoverage EXPLAIN QUERY PLAN:\n\(details.joined(separator: "\n"))")
        #expect(
            details.contains { $0.hasPrefix("SEARCH lc ") },
            "expected an indexed lyricsCache seek per track, got: \(details)"
        )
        #expect(
            !details.contains { $0 == "SCAN lc" || $0.hasPrefix("SCAN lc ") },
            "expected no lyricsCache scan, got: \(details)"
        )
    }
}
