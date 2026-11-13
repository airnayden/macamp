import Foundation
import GRDB
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct LibraryViewModelTests {
    private func makeModel(
        _ database: AppDatabase,
        pageSize: Int = 100,
        recentLimit: Int = 50
    ) -> LibraryViewModel {
        LibraryViewModel(
            trackRepository: TrackRepository(database),
            albumRepository: AlbumRepository(database),
            artistRepository: ArtistRepository(database),
            databaseReader: database.writer,
            pageSize: pageSize,
            recentLimit: recentLimit
        )
    }

    @Test func recentlyAddedObservationReflectsInsert() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let model = LibraryViewModel(
            trackRepository: repository,
            albumRepository: AlbumRepository(database),
            artistRepository: ArtistRepository(database),
            databaseReader: database.writer,
            recentLimit: 10
        )
        model.startObservingRecentlyAdded()
        // `.immediate` delivers the initial (empty) value synchronously.
        #expect(model.recentlyAdded.isEmpty)

        try repository.insert(makeTrackRecord(filePath: "/music/a.flac", title: "Alpha", dateAdded: 1))
        await pollUntil { model.recentlyAdded.count == 1 }
        #expect(model.recentlyAdded.count == 1)
        #expect(model.recentlyAdded.first?.title == "Alpha")

        try repository.insert(makeTrackRecord(filePath: "/music/b.flac", title: "Bravo", dateAdded: 2))
        await pollUntil { model.recentlyAdded.count == 2 }
        #expect(model.recentlyAdded.count == 2)
        // Ordered by dateAdded DESC — newest first.
        #expect(model.recentlyAdded.first?.title == "Bravo")
        model.stopObservingRecentlyAdded()
    }

    @Test func recentlyAddedObservationIsWindowed() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let model = makeModel(database, recentLimit: 5)
        for index in 0 ..< 20 {
            try repository.insert(makeTrackRecord(
                filePath: "/music/track-\(index).flac",
                title: "Track \(index)",
                dateAdded: Double(index)
            ))
        }
        model.startObservingRecentlyAdded()
        await pollUntil { model.recentlyAdded.count == 5 }
        // Bounded to the LIMIT — never the whole 20-row table.
        #expect(model.recentlyAdded.count == 5)
        model.stopObservingRecentlyAdded()
    }

    @Test func tracksPaginateByKeyset() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        for index in 0 ..< 5 {
            try repository.insert(makeTrackRecord(
                filePath: "/music/p-\(index).flac",
                title: String(format: "Song %02d", index)
            ))
        }
        let model = makeModel(database, pageSize: 2)
        try await model.loadInitialTracks()
        #expect(model.tracks.count == 2)
        #expect(model.hasMoreTracks)

        try await model.loadMoreTracks()
        #expect(model.tracks.count == 4)

        try await model.loadMoreTracks()
        #expect(model.tracks.count == 5)
        #expect(!model.hasMoreTracks)
    }

    @Test func badgeMapsAvailability() throws {
        let database = try AppDatabase.makeEmpty()
        let model = makeModel(database)
        let present = makeTrackRecord(filePath: "/m/p.flac", title: "P", availability: .present)
        let missing = makeTrackRecord(filePath: "/m/m.flac", title: "M", availability: .missing)
        let offline = makeTrackRecord(filePath: "/m/o.flac", title: "O", availability: .externalOffline)
        #expect(model.badge(for: present) == .available)
        #expect(model.badge(for: missing) == .missing)
        #expect(model.badge(for: offline) == .offline)
    }
}
