import Foundation
import Persistence
import Testing

/// Correctness for the bounded, profile-scoped ``TrackRepository/tracksByPaths``
/// query (Todo 5): path-set membership, ``LibraryVisibility`` scoping, keyset
/// pagination, and the chunk-merge that pages a path set larger than the SQLite
/// `IN (…)` bound-variable limit. All run on `AppDatabase.makeEmpty()`.
@Suite("TracksByPathsTests")
struct TracksByPathsTests {
    private struct Harness {
        let database: AppDatabase
        let tracks: TrackRepository
        let profiles: ProfileRepository
        let roots: LibraryRootRepository
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.makeEmpty()
        return Harness(
            database: database,
            tracks: TrackRepository(database),
            profiles: ProfileRepository(database),
            roots: LibraryRootRepository(database)
        )
    }

    @discardableResult
    private func seedTrack(
        _ tracks: TrackRepository,
        path: String,
        title: String,
        availability: Availability = .present
    ) throws -> Int64 {
        let record = try tracks.insert(TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title.lowercased(),
            availability: availability
        ))
        return try #require(record.id)
    }

    private func makeProfile(_ profiles: ProfileRepository, name: String) throws -> Int64 {
        let created = try profiles.create(ProfileRecord(name: name))
        return try #require(created.id)
    }

    @Test("returns only in-set paths visible to the profile; a rival's owned track never leaks")
    func scopedToProfileAndPathSet() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        let bern = try makeProfile(harness.profiles, name: "Bern")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: bern, path: "/Music/Bern")

        try seedTrack(harness.tracks, path: "/Music/Alex/a.flac", title: "Alpha")
        try seedTrack(harness.tracks, path: "/Music/Bern/b.flac", title: "Bravo")
        try seedTrack(harness.tracks, path: "/Loose/l.flac", title: "Charlie")
        let queryPaths = [
            "/Music/Alex/a.flac",
            "/Music/Bern/b.flac",
            "/Loose/l.flac",
            "/Music/Alex/absent.flac",
        ]

        let alexRows = try harness.tracks.tracksByPaths(profileId: alex, paths: queryPaths, after: nil, limit: 100)
        let bernRows = try harness.tracks.tracksByPaths(profileId: bern, paths: queryPaths, after: nil, limit: 100)

        #expect(alexRows.compactMap(\.track.title) == ["Alpha", "Charlie"])
        #expect(bernRows.compactMap(\.track.title) == ["Bravo", "Charlie"])
    }

    @Test("count matches the library-resolved subset and stays zero for an empty library")
    func countMatchesResolvedRows() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        let bern = try makeProfile(harness.profiles, name: "Bern")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: bern, path: "/Music/Bern")
        let readyPaths = [
            "/Music/Alex/a.flac",
            "/Music/Alex/b.flac",
            "/Music/Bern/c.flac",
        ]

        #expect(try harness.tracks.countTracksByPaths(profileId: alex, paths: readyPaths) == 0)

        try seedTrack(harness.tracks, path: readyPaths[0], title: "Alpha")
        try seedTrack(harness.tracks, path: readyPaths[1], title: "Bravo")
        try seedTrack(harness.tracks, path: readyPaths[2], title: "Charlie")

        let alexRows = try harness.tracks.tracksByPaths(profileId: alex, paths: readyPaths, limit: 100)
        #expect(try harness.tracks.countTracksByPaths(profileId: alex, paths: readyPaths) == alexRows.count)
        #expect(alexRows.count == 2)
        #expect(try harness.tracks.countTracksByPaths(profileId: bern, paths: readyPaths) == 1)
    }

    @Test("missing and external-offline tracks are excluded from ready results")
    func unavailableTracksAreExcluded() throws {
        let harness = try makeHarness()
        let paths = ["/Music/present.flac", "/Music/missing.flac", "/Music/offline.flac"]
        try seedTrack(harness.tracks, path: paths[0], title: "Present")
        try seedTrack(harness.tracks, path: paths[1], title: "Missing", availability: .missing)
        try seedTrack(harness.tracks, path: paths[2], title: "Offline", availability: .externalOffline)

        let rows = try harness.tracks.tracksByPaths(paths: paths, limit: 100)

        #expect(rows.compactMap(\.track.title) == ["Present"])
        #expect(try harness.tracks.countTracksByPaths(paths: paths) == 1)
    }

    @Test("count chunks more than 500 ready paths without double-counting duplicate inputs")
    func countChunksLargePathSets() throws {
        let harness = try makeHarness()
        let paths = (0 ..< 600).map { "/Music/\($0).flac" }
        try seedTrack(harness.tracks, path: paths[0], title: "Alpha")
        try seedTrack(harness.tracks, path: paths[599], title: "Omega")

        let count = try harness.tracks.countTracksByPaths(
            paths: paths + [paths[0], paths[599]]
        )

        #expect(count == 2)
    }

    @Test("limit 2 over 5 matches walks all 5 across pages with no duplicates")
    func paginationWalksAllMatches() throws {
        let harness = try makeHarness()
        let titles = ["Track A", "Track B", "Track C", "Track D", "Track E"]
        var paths: [String] = []
        for (index, title) in titles.enumerated() {
            let path = "/Music/\(index).flac"
            paths.append(path)
            try seedTrack(harness.tracks, path: path, title: title)
        }

        var collected: [String] = []
        var cursor: PageCursor<String>?
        while true {
            let page = try harness.tracks.tracksByPaths(
                profileId: ProfileRecord.guestID, paths: paths, after: cursor, limit: 2
            )
            if page.isEmpty { break }
            collected.append(contentsOf: page.compactMap(\.track.title))
            let last = try #require(page.last)
            let lastID = try #require(last.track.id)
            cursor = PageCursor(key: last.track.sortTitle ?? "", id: lastID)
            if page.count < 2 { break }
        }

        #expect(collected == titles)
        #expect(Set(collected).count == titles.count)
    }

    @Test("more than 500 paths chunk and merge into one globally-ordered page")
    func chunksBeyondSQLiteVariableLimit() throws {
        let harness = try makeHarness()
        let total = 600
        var paths: [String] = []
        paths.reserveCapacity(total)
        for index in 0 ..< total {
            let path = "/Music/\(index).flac"
            paths.append(path)
            // Reverse the sort key against the path/chunk order: path 0 sorts LAST and
            // path 599 sorts FIRST, so the global first page is drawn entirely from the
            // SECOND chunk — proving the merge sorts across chunks, not concatenates.
            try seedTrack(harness.tracks, path: path, title: String(format: "Track %04d", total - 1 - index))
        }

        let firstPage = try harness.tracks.tracksByPaths(
            profileId: ProfileRecord.guestID, paths: paths, after: nil, limit: 100
        )
        #expect(firstPage.count == 100)
        #expect(firstPage.compactMap(\.track.title) == (0 ..< 100).map { String(format: "Track %04d", $0) })

        var seen: [Int64] = []
        var cursor: PageCursor<String>?
        while true {
            let page = try harness.tracks.tracksByPaths(
                profileId: ProfileRecord.guestID, paths: paths, after: cursor, limit: 100
            )
            if page.isEmpty { break }
            seen.append(contentsOf: page.compactMap(\.track.id))
            let last = try #require(page.last)
            let lastID = try #require(last.track.id)
            cursor = PageCursor(key: last.track.sortTitle ?? "", id: lastID)
            if page.count < 100 { break }
        }
        #expect(seen.count == total)
        #expect(Set(seen).count == total)
    }

    @Test("an empty path set returns an empty result with no query error")
    func emptyPathSetReturnsEmpty() throws {
        let harness = try makeHarness()
        try seedTrack(harness.tracks, path: "/Music/a.flac", title: "Alpha")

        let rows = try harness.tracks.tracksByPaths(profileId: ProfileRecord.guestID, paths: [], after: nil, limit: 100)
        #expect(rows.isEmpty)
    }

    @Test("each row carries this profile's resolved favourite state, not the frozen column")
    func rowsCarryProfileResolvedState() async throws {
        let harness = try makeHarness()
        let favedID = try seedTrack(harness.tracks, path: "/Music/a.flac", title: "Alpha")
        try seedTrack(harness.tracks, path: "/Music/b.flac", title: "Bravo")
        try await harness.tracks.setFavourite(profileId: ProfileRecord.guestID, trackId: favedID, isFavourite: true)

        let rows = try harness.tracks.tracksByPaths(
            profileId: ProfileRecord.guestID,
            paths: ["/Music/a.flac", "/Music/b.flac"],
            after: nil,
            limit: 100
        )

        let favedRow = try #require(rows.first { $0.track.id == favedID })
        let otherRow = try #require(rows.first { $0.track.title == "Bravo" })
        #expect(favedRow.isFavourite)
        #expect(otherRow.isFavourite == false)
    }
}
