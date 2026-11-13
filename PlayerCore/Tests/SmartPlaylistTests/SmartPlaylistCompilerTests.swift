import Foundation
import Persistence
import Testing

@Suite("SmartPlaylistCompilerTests")
struct SmartPlaylistCompilerTests {
    @Test("Genre matches exactly and case-insensitively")
    func compilesGenre() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let ids = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.genre(equals: "Rock")))
        )

        #expect(ids.sorted() == [1, 2, 4])
    }

    @Test("Artist and album match exactly")
    func compilesArtistAndAlbum() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let byArtist = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.artistName(equals: "Alpha")))
        )
        let byAlbum = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.albumTitle(equals: "Second")))
        )

        #expect(byArtist.sorted() == [1, 2])
        #expect(byAlbum.sorted() == [3])
    }

    @Test("Year, duration and dateAdded ranges are inclusive on both bounds")
    func compilesRanges() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let byYear = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.year(range: SmartPlaylistRange(lower: 1990, upper: 1999))))
        )
        let byDuration = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.duration(range: SmartPlaylistRange(lower: 200, upper: 300))))
        )
        let byDateAdded = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.dateAdded(range: SmartPlaylistRange(lower: 2000))))
        )

        #expect(byYear.sorted() == [1, 3, 4])
        #expect(byDuration.sorted() == [1, 2])
        #expect(byDateAdded.sorted() == [2, 3, 4])
    }

    @Test("A range with neither bound constrains nothing")
    func openRangeMatchesEverything() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let ids = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.year(range: SmartPlaylistRange<Int>())))
        )

        #expect(ids.sorted() == [1, 2, 3, 4])
    }

    @Test("Availability filters on the three-state column")
    func compilesAvailability() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let present = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.availability(equals: .present)))
        )
        let missing = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.metadata(.availability(equals: .missing)))
        )

        #expect(present.sorted() == [1, 2, 4])
        #expect(missing.sorted() == [3])
    }

    @Test("Profile stats read profileTrackState, with an absent sparse row as zero/false")
    func compilesProfileStats() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let played = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.profileStat(.playCount(range: SmartPlaylistRange(lower: 5))))
        )
        let barelyListened = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.profileStat(.listenedCount(range: SmartPlaylistRange(upper: 1))))
        )
        let favourites = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.profileStat(.isFavourite(equals: true)))
        )

        #expect(played.sorted() == [1])
        #expect(barelyListened.sorted() == [2, 3, 4])
        #expect(favourites.sorted() == [1])
    }

    @Test("A profile's stats never leak into another profile's rules")
    func profileStatsAreScoped() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        try database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.otherProfileID, name: "Profile B")
        }

        let favourites = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.profileStat(.isFavourite(equals: true))),
            profileId: SmartPlaylistFixtures.otherProfileID
        )

        #expect(favourites.isEmpty)
    }

    @Test("Recency windows read raw playEvent rows for this profile")
    func compilesRecency() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let recent = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.recency(.playedWithin(days: 7)))
        )
        let dormant = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.recency(.notPlayedWithin(days: 7)))
        )

        #expect(recent.sorted() == [1])
        #expect(dormant.sorted() == [2, 3, 4])
    }

    @Test("An audio-feature range never excludes an un-analysed track")
    func audioFeaturesAreNoOpWhenAbsent() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let energetic = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(
                .audioFeature(.energy(range: SmartPlaylistRange(lower: 0.5, upper: 1.0)))
            )
        )
        let midTempo = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(
                .audioFeature(.bpm(range: SmartPlaylistRange(lower: 120, upper: 140)))
            )
        )

        #expect(energetic.sorted() == [1, 2, 3])
        #expect(midTempo.sorted() == [1, 2, 3, 4])
    }

    @Test("Brightness behaves like the other feature ranges")
    func compilesBrightness() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let bright = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(
                .audioFeature(.brightness(range: SmartPlaylistRange(lower: 0.5)))
            )
        )

        #expect(bright.sorted() == [1, 2, 3])
    }
}
