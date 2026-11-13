import Foundation
import GRDB
import Persistence
import Testing

@Suite("LibraryVisibilityTests")
struct LibraryVisibilityTests {
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
        genre: String? = nil
    ) throws -> Int64 {
        let record = try tracks.insert(TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title.lowercased(),
            genre: genre
        ))
        return try #require(record.id)
    }

    private func makeProfile(_ profiles: ProfileRepository, name: String) throws -> Int64 {
        let created = try profiles.create(ProfileRecord(name: name))
        return try #require(created.id)
    }

    private func visibleTitles(_ tracks: TrackRepository, profileId: Int64) throws -> Set<String> {
        let page = try tracks.tracksPage(profileId: profileId, after: nil, limit: 1000)
        return Set(page.items.compactMap(\.title))
    }

    @Test("a profile with root A sees only its own tracks plus ownerless files")
    func profileSeesOwnRootsAndOwnerless() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness.tracks, path: "/Music/Alex/a1.flac", title: "Alpha")
        try seedTrack(harness.tracks, path: "/Music/Alex/a2.flac", title: "Bravo")
        try seedTrack(harness.tracks, path: "/Music/Guest/g1.flac", title: "Charlie")
        try seedTrack(harness.tracks, path: "/Loose/loose.flac", title: "Delta")

        let titles = try visibleTitles(harness.tracks, profileId: alex)
        #expect(titles == ["Alpha", "Bravo", "Delta"])
    }

    @Test("a profile never sees another profile's owned tracks")
    func profileDoesNotSeeAnotherProfilesTracks() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness.tracks, path: "/Music/Alex/a1.flac", title: "Alpha")
        try seedTrack(harness.tracks, path: "/Music/Guest/g1.flac", title: "Charlie")
        try seedTrack(harness.tracks, path: "/Loose/loose.flac", title: "Delta")

        let guestTitles = try visibleTitles(harness.tracks, profileId: ProfileRecord.guestID)
        #expect(guestTitles == ["Charlie", "Delta"])
    }

    @Test("a brand-new profile with zero roots sees only ownerless tracks")
    func newProfileSeesOnlyOwnerless() throws {
        let harness = try makeHarness()
        let newbie = try makeProfile(harness.profiles, name: "Newbie")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness.tracks, path: "/Music/Guest/g1.flac", title: "Charlie")
        try seedTrack(harness.tracks, path: "/Loose/loose.flac", title: "Delta")

        let titles = try visibleTitles(harness.tracks, profileId: newbie)
        #expect(titles == ["Delta"])
    }

    @Test("a loose file under no configured root is visible to every profile")
    func ownerlessVisibleToEveryProfile() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")
        try seedTrack(harness.tracks, path: "/Loose/loose.flac", title: "Delta")

        #expect(try visibleTitles(harness.tracks, profileId: alex) == ["Delta"])
        #expect(try visibleTitles(harness.tracks, profileId: ProfileRecord.guestID) == ["Delta"])
    }

    @Test("with no roots configured anywhere every track is visible to every profile")
    func noRootsMeansEverythingVisible() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try seedTrack(harness.tracks, path: "/Music/x/1.flac", title: "One")
        try seedTrack(harness.tracks, path: "/Music/y/2.flac", title: "Two")

        #expect(try visibleTitles(harness.tracks, profileId: alex) == ["One", "Two"])
        #expect(try visibleTitles(harness.tracks, profileId: ProfileRecord.guestID) == ["One", "Two"])
    }

    @Test("full-text search is scoped to the profile's visible tracks")
    func searchScopedToProfile() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness.tracks, path: "/Music/Alex/a.flac", title: "Bohemian Rhapsody")
        try seedTrack(harness.tracks, path: "/Music/Guest/g.flac", title: "Bohemian Like You")
        try seedTrack(harness.tracks, path: "/Loose/l.flac", title: "Bohemian Loose")

        let alexResults = try harness.tracks.searchTracks(profileId: alex, query: "bohemian", limit: 50)
        #expect(Set(alexResults.compactMap(\.title)) == ["Bohemian Rhapsody", "Bohemian Loose"])

        let guestResults = try harness.tracks.searchTracks(
            profileId: ProfileRecord.guestID,
            query: "bohemian",
            limit: 50
        )
        #expect(Set(guestResults.compactMap(\.title)) == ["Bohemian Like You", "Bohemian Loose"])
    }

    @Test("genre browsing is scoped to the profile's visible tracks")
    func genreBrowsingScopedToProfile() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        try seedTrack(harness.tracks, path: "/Music/Alex/a.flac", title: "AlexJazz", genre: "Jazz")
        try seedTrack(harness.tracks, path: "/Music/Guest/g.flac", title: "GuestRock", genre: "Rock")
        try seedTrack(harness.tracks, path: "/Loose/l.flac", title: "LooseJazz", genre: "Jazz")

        let jazz = try harness.tracks.tracksByGenre(profileId: alex, genre: "Jazz", after: nil, limit: 100)
        #expect(Set(jazz.items.compactMap(\.title)) == ["AlexJazz", "LooseJazz"])

        let rock = try harness.tracks.tracksByGenre(profileId: alex, genre: "Rock", after: nil, limit: 100)
        #expect(rock.items.isEmpty)
    }

    @Test("an album is visible only when it owns a track visible to the profile")
    func albumsScopedByTrackVisibility() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Guest")

        let albums = AlbumRepository(harness.database)
        let alexAlbum = try albums.insert(AlbumRecord(title: "Alex Album", sortTitle: "alex album"))
        let guestAlbum = try albums.insert(AlbumRecord(title: "Guest Album", sortTitle: "guest album"))
        _ = try harness.tracks.insert(TrackRecord(
            filePath: "/Music/Alex/a.flac", title: "AT", sortTitle: "at", albumId: alexAlbum.id
        ))
        _ = try harness.tracks.insert(TrackRecord(
            filePath: "/Music/Guest/g.flac", title: "GT", sortTitle: "gt", albumId: guestAlbum.id
        ))

        let page = try albums.albumsWithTrackCounts(profileId: alex, after: nil, limit: 100)
        #expect(Set(page.items.compactMap(\.album.title)) == ["Alex Album"])
    }

    @Test("removing a profile's root hides its tracks but keeps the favourite state row")
    func removingRootHidesTracksButKeepsState() async throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music")
        let alexRoot = try harness.roots.addRoot(profileId: alex, path: "/Music/Alex")
        let alexRootId = try #require(alexRoot.id)
        let trackId = try seedTrack(harness.tracks, path: "/Music/Alex/a.flac", title: "Fav")

        try await harness.tracks.setFavourite(profileId: alex, trackId: trackId, isFavourite: true)
        #expect(try visibleTitles(harness.tracks, profileId: alex) == ["Fav"])

        _ = try harness.roots.removeRoot(id: alexRootId)

        // The file is still under Guest's /Music root, so it is NOT ownerless and
        // is hidden from Alex, who no longer owns a matching root.
        #expect(try visibleTitles(harness.tracks, profileId: alex).isEmpty)
        // Guest still sees it (under /Music); Alex's favourite state row survives.
        #expect(try visibleTitles(harness.tracks, profileId: ProfileRecord.guestID) == ["Fav"])
        let favourites = try harness.tracks.favouriteTrackIDs(profileId: alex)
        #expect(favourites.contains(trackId))
    }

    @Test("sparse-profile first-page latency stays within the perf budget")
    func sparseProfileFirstPageWithinBudget() throws {
        let harness = try makeHarness()
        let alex = try makeProfile(harness.profiles, name: "Sparse")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Owned")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Bulk")

        // 100k tracks: ~0.1% (every 1000th) under Alex's root, the rest under
        // Guest's — the worst selectivity case, with Alex's rows spread across the
        // whole sortTitle scan so the first page must scan deep to fill.
        let total = 100_000
        let ownedEvery = 1000
        var batch: [TrackRecord] = []
        batch.reserveCapacity(10000)
        for index in 0 ..< total {
            let root = index % ownedEvery == 0 ? "/Music/Owned" : "/Music/Bulk"
            let title = String(format: "Track %06d", index)
            batch.append(TrackRecord(filePath: "\(root)/\(index).flac", title: title, sortTitle: title.lowercased()))
            if batch.count == 10000 {
                _ = try harness.tracks.insertBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { _ = try harness.tracks.insertBatch(batch) }

        _ = try harness.tracks.tracksPage(profileId: alex, after: nil, limit: 100)
        let start = CFAbsoluteTimeGetCurrent()
        let page = try harness.tracks.tracksPage(profileId: alex, after: nil, limit: 100)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let allOwned = page.items.allSatisfy { $0.filePath.hasPrefix("/Music/Owned/") }
        #expect(page.items.count == 100)
        #expect(allOwned)
        #expect(elapsed < 0.30, "sparse-profile first page took \(elapsed * 1000)ms, expected < 300ms")
    }
}
