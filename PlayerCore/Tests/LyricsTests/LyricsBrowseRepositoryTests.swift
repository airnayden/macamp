import Foundation
import GRDB
@testable import Lyrics
import Persistence
import Testing

@Suite("LyricsBrowseRepositoryTests")
struct LyricsBrowseRepositoryTests {
    private struct Harness {
        let database: AppDatabase
        let tracks: TrackRepository
        let profiles: ProfileRepository
        let roots: LibraryRootRepository
        let cache: GRDBLyricsCache
        let browse: LyricsBrowseRepository
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.makeEmpty()
        return Harness(
            database: database,
            tracks: TrackRepository(database),
            profiles: ProfileRepository(database),
            roots: LibraryRootRepository(database),
            cache: GRDBLyricsCache(database),
            browse: LyricsBrowseRepository(database)
        )
    }

    @discardableResult
    private func seedTrack(
        _ harness: Harness,
        path: String,
        title: String,
        artist: String? = nil,
        duration: Double? = nil,
        availability: Availability = .present
    ) throws -> Int64 {
        let record = try harness.tracks.insert(TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title.lowercased(),
            artistName: artist,
            duration: duration,
            availability: availability
        ))
        return try #require(record.id)
    }

    private func syncedLyrics() -> Lyrics {
        Lyrics(lines: [LyricLine(time: 0, text: "one"), LyricLine(time: 3, text: "two")], source: .lrcFile)
    }

    private func plainLyrics() -> Lyrics {
        Lyrics(lines: [LyricLine(text: "one"), LyricLine(text: "two")], source: .embeddedUnsynced)
    }

    /// Writes a negative-probe row the way the offline sweep will: `source = "none"`
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

    private func titles(_ page: Page<LyricsRowDTO, String>) -> [String] {
        page.items.compactMap(\.title)
    }

    // MARK: - Membership

    @Test("only tracks with a non-sentinel cache row appear, ordered by (sortTitle, id)")
    func listsCachedTracksInSortOrder() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/charlie.flac", title: "Charlie")
        try seedTrack(harness, path: "/M/alpha.flac", title: "Alpha")
        try seedTrack(harness, path: "/M/bravo.flac", title: "Bravo")
        try seedTrack(harness, path: "/M/delta.flac", title: "Delta")

        try harness.cache.store(syncedLyrics(), forKey: "/M/charlie.flac")
        try harness.cache.store(plainLyrics(), forKey: "/M/alpha.flac")
        try harness.cache.store(plainLyrics(), forKey: "/M/bravo.flac")

        let page = try harness.browse.tracksWithLyrics(limit: 100)

        #expect(titles(page) == ["Alpha", "Bravo", "Charlie"])
        #expect(page.nextCursor == nil)
        try #expect(harness.browse.tracksWithLyricsCount() == 3)
    }

    @Test("negative-result sentinel rows are excluded")
    func excludesNegativeSentinels() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/has.flac", title: "Has")
        try seedTrack(harness, path: "/M/probed.flac", title: "Probed")
        try harness.cache.store(plainLyrics(), forKey: "/M/has.flac")
        try seedSentinel(harness, forKey: "/M/probed.flac")

        let page = try harness.browse.tracksWithLyrics(limit: 100)

        #expect(titles(page) == ["Has"])
        try #expect(harness.browse.tracksWithLyricsCount() == 1)
    }

    @Test("missing and external-offline tracks are excluded even when cached")
    func excludesNonPresentTracks() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/here.flac", title: "Here")
        try seedTrack(harness, path: "/M/gone.flac", title: "Gone", availability: .missing)
        try seedTrack(harness, path: "/M/unplugged.flac", title: "Unplugged", availability: .externalOffline)
        for path in ["/M/here.flac", "/M/gone.flac", "/M/unplugged.flac"] {
            try harness.cache.store(plainLyrics(), forKey: path)
        }

        let page = try harness.browse.tracksWithLyrics(limit: 100)

        #expect(titles(page) == ["Here"])
    }

    @Test("legacy composite-key cache rows match no track and are simply skipped")
    func compositeKeyRowsDoNotMatch() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/song.flac", title: "Song", artist: "Band", duration: 200)
        let composite = LyricsRequest(title: "Song", artist: "Band", duration: 200).cacheKey
        try harness.cache.store(plainLyrics(), forKey: composite)

        let page = try harness.browse.tracksWithLyrics(limit: 100)

        #expect(composite == "Band|Song||200")
        #expect(page.items.isEmpty)
        try #expect(harness.browse.tracksWithLyricsCount() == 0)
    }

    @Test("a track appears exactly once — the unique cacheKey cannot multiply rows")
    func joinDoesNotDuplicateRows() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/song.flac", title: "Song")
        try harness.cache.store(plainLyrics(), forKey: "/M/song.flac")
        try harness.cache.store(syncedLyrics(), forKey: "/M/song.flac")

        let page = try harness.browse.tracksWithLyrics(limit: 100)

        #expect(page.items.count == 1)
        #expect(page.items.first?.isSynced == true)
    }

    // MARK: - Row shape

    @Test("the row carries the identity, display text and the synced flag")
    func rowCarriesSyncedFlagAndDisplayFields() throws {
        let harness = try makeHarness()
        let syncedID = try seedTrack(
            harness,
            path: "/M/synced.flac",
            title: "Synced",
            artist: "Artist",
            duration: 212.5
        )
        try seedTrack(harness, path: "/M/plain.flac", title: "Plain")
        try harness.cache.store(syncedLyrics(), forKey: "/M/synced.flac")
        try harness.cache.store(plainLyrics(), forKey: "/M/plain.flac")

        let rows = try harness.browse.tracksWithLyrics(limit: 100).items
        let synced = try #require(rows.first { $0.title == "Synced" })
        let plain = try #require(rows.first { $0.title == "Plain" })

        #expect(synced.trackId == syncedID)
        #expect(synced.filePath == "/M/synced.flac")
        #expect(synced.artist == "Artist")
        #expect(synced.duration == 212.5)
        #expect(synced.isSynced)
        #expect(!plain.isSynced)
    }

    @Test("an undecodable payload keeps the row but reports it unsynced")
    func corruptPayloadDegradesToUnsynced() throws {
        let harness = try makeHarness()
        try seedTrack(harness, path: "/M/broken.flac", title: "Broken")
        try harness.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO lyricsCache (cacheKey, source, payloadJson, fetchedAt) VALUES (?, ?, ?, ?)",
                arguments: ["/M/broken.flac", LyricsSource.lrcFile.rawValue, "{not json", 0.0]
            )
        }

        let rows = try harness.browse.tracksWithLyrics(limit: 100).items

        #expect(rows.count == 1)
        #expect(rows.first?.isSynced == false)
    }

    // MARK: - Keyset paging

    @Test("keyset pages cover every row exactly once")
    func pagesDoNotDuplicateOrSkipRows() throws {
        let harness = try makeHarness()
        let expected = (0 ..< 7).map { String(format: "Track %02d", $0) }
        for title in expected {
            let path = "/M/\(title).flac"
            try seedTrack(harness, path: path, title: title)
            try harness.cache.store(plainLyrics(), forKey: path)
        }

        var seen: [String] = []
        var cursor: PageCursor<String>?
        var pages = 0
        repeat {
            let page = try harness.browse.tracksWithLyrics(after: cursor, limit: 3)
            seen.append(contentsOf: titles(page))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(seen == expected)
        #expect(Set(seen).count == seen.count)
    }

    @Test("rows with no sortTitle still page without breaking the keyset")
    func nullSortTitlesPageTotally() throws {
        let harness = try makeHarness()
        for index in 0 ..< 4 {
            let path = "/M/untitled\(index).flac"
            _ = try harness.tracks.insert(TrackRecord(filePath: path, title: nil, sortTitle: nil))
            try harness.cache.store(plainLyrics(), forKey: path)
        }

        var ids: [Int64] = []
        var cursor: PageCursor<String>?
        var pages = 0
        repeat {
            let page = try harness.browse.tracksWithLyrics(after: cursor, limit: 2)
            ids.append(contentsOf: page.items.map(\.trackId))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(ids.count == 4)
        #expect(Set(ids).count == 4)
        #expect(ids == ids.sorted())
    }

    // MARK: - Profile scoping

    @Test("two profiles with disjoint roots never see each other's cached tracks")
    func profilesWithDisjointRootsAreIsolated() throws {
        let harness = try makeHarness()
        let alex = try #require(try harness.profiles.create(ProfileRecord(name: "Alex")).id)
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness, path: "/Music/Alex/a.flac", title: "Alpha")
        try seedTrack(harness, path: "/Music/Guest/g.flac", title: "Gamma")
        try seedTrack(harness, path: "/Loose/loose.flac", title: "Loose")
        for path in ["/Music/Alex/a.flac", "/Music/Guest/g.flac", "/Loose/loose.flac"] {
            try harness.cache.store(plainLyrics(), forKey: path)
        }

        let alexPage = try harness.browse.tracksWithLyrics(profileId: alex, limit: 100)
        let guestPage = try harness.browse.tracksWithLyrics(profileId: ProfileRecord.guestID, limit: 100)

        #expect(titles(alexPage) == ["Alpha", "Loose"])
        #expect(titles(guestPage) == ["Gamma", "Loose"])
        try #expect(harness.browse.tracksWithLyricsCount(profileId: alex) == 2)
        try #expect(harness.browse.tracksWithLyricsCount(profileId: ProfileRecord.guestID) == 2)
    }

    @Test("with no roots configured every cached track is visible to every profile")
    func ownerlessLibraryIsVisibleToAll() throws {
        let harness = try makeHarness()
        let alex = try #require(try harness.profiles.create(ProfileRecord(name: "Alex")).id)
        try seedTrack(harness, path: "/M/a.flac", title: "Alpha")
        try harness.cache.store(plainLyrics(), forKey: "/M/a.flac")

        try #expect(titles(harness.browse.tracksWithLyrics(profileId: alex, limit: 100)) == ["Alpha"])
        try #expect(titles(harness.browse.tracksWithLyrics(limit: 100)) == ["Alpha"])
    }

    @Test("an empty library reports a zero count and an empty page")
    func emptyLibraryIsWellFormed() throws {
        let harness = try makeHarness()

        let page = try harness.browse.tracksWithLyrics(limit: 100)

        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
        try #expect(harness.browse.tracksWithLyricsCount() == 0)
    }
}
