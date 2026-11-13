// LibraryViewModelQoSTests — proves library keyset pagination never performs a
// blocking GRDB read on the main actor (the QoS priority-inversion "hang risk").
//
// `LibraryViewModel` is `@MainActor`. A synchronous `dbWriter.read { }` invoked
// from the main actor blocks the main thread (`.userInteractive`) while it waits
// for one of the DatabasePool's 5 readers (`.userInitiated`) — a priority
// inversion that Xcode's Thread Performance Checker flags as a Hang Risk. The
// recorder below counts how many times the *synchronous* (blocking) read is
// entered while on the main thread; the async overload suspends instead, so after
// the fix the blocking-on-main count must be zero while the async path is taken.
import Foundation
import GRDB
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct LibraryViewModelQoSTests {
    @Test func loadInitialTracksPerformsNoBlockingReadOnMainThread() async throws {
        let database = try AppDatabase.makeEmpty()
        let base = TrackRepository(database)
        for index in 0 ..< 6 {
            try base.insert(makeTrackRecord(
                filePath: "/music/qos-\(index).flac",
                title: String(format: "Song %02d", index)
            ))
        }
        let recorder = MainThreadBlockingReadRecorder(base)
        let model = LibraryViewModel(
            trackRepository: recorder,
            albumRepository: AlbumRepository(database),
            artistRepository: ArtistRepository(database),
            databaseReader: database.writer,
            pageSize: 2
        )

        try await model.loadInitialTracks()
        try await model.loadMoreTracks()

        #expect(model.tracks.count == 4)
        #expect(recorder.asyncReads > 0)
        #expect(recorder.mainThreadBlockingReads == 0)
    }
}

/// A ``TrackRepositoryProviding`` decorator that counts how many times a
/// *synchronous* (blocking) read is entered while on the main thread, versus how
/// many *async* reads are taken. After the fix the model must use the async path
/// exclusively, leaving `mainThreadBlockingReads` at zero.
private final class MainThreadBlockingReadRecorder: TrackRepositoryProviding, @unchecked Sendable {
    private let base: TrackRepository
    private let lock = NSLock()
    private var blockingReadsOnMain = 0
    private var asyncReadCount = 0

    init(_ base: TrackRepository) {
        self.base = base
    }

    var mainThreadBlockingReads: Int {
        lock.withLock { blockingReadsOnMain }
    }

    var asyncReads: Int {
        lock.withLock { asyncReadCount }
    }

    func tracksPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<TrackRecord, String> {
        if Thread.isMainThread { lock.withLock { blockingReadsOnMain += 1 } }
        return try base.tracksPage(profileId: profileId, after: cursor, limit: limit)
    }

    func tracksPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) async throws -> Page<TrackRecord, String> {
        lock.withLock { asyncReadCount += 1 }
        return try await base.tracksPage(profileId: profileId, after: cursor, limit: limit)
    }

    func tracksByRoot(
        profileId: Int64,
        rootPath: String,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) throws -> Page<TrackRecord, Int64> {
        try base.tracksByRoot(profileId: profileId, rootPath: rootPath, after: cursor, limit: limit)
    }

    func updateFolderPositions(
        profileId: Int64,
        rootPath: String,
        _ updates: [(trackId: Int64, position: Int)]
    ) async throws {
        try await base.updateFolderPositions(profileId: profileId, rootPath: rootPath, updates)
    }

    func rootSummary(rootPath: String) throws -> RootTrackSummary {
        try base.rootSummary(rootPath: rootPath)
    }

    func distinctGenres() async throws -> LibraryGenreFacets {
        try await base.distinctGenres()
    }

    func tracksByGenre(
        profileId: Int64,
        genre: String?,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) throws -> Page<TrackRecord, Int64> {
        try base.tracksByGenre(profileId: profileId, genre: genre, after: cursor, limit: limit)
    }

    func tracksByAlbum(
        albumId: Int64,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) throws -> Page<TrackRecord, Int64> {
        try base.tracksByAlbum(albumId: albumId, after: cursor, limit: limit)
    }

    func tracksByArtist(
        artistId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<TrackRecord, String> {
        try base.tracksByArtist(artistId: artistId, after: cursor, limit: limit)
    }

    func fetchTrack(id: Int64) throws -> TrackRecord? {
        try base.fetchTrack(id: id)
    }

    func fetchTrack(filePath: String) throws -> TrackRecord? {
        try base.fetchTrack(filePath: filePath)
    }

    @discardableResult func insert(_ track: TrackRecord) throws -> TrackRecord {
        try base.insert(track)
    }

    func update(_ track: TrackRecord) throws {
        try base.update(track)
    }

    @discardableResult func deleteTrack(id: Int64) throws -> Bool {
        try base.deleteTrack(id: id)
    }

    @discardableResult func insertBatch(_ tracks: [TrackRecord]) throws -> Int {
        try base.insertBatch(tracks)
    }

    func searchTracks(profileId: Int64, query: String, limit: Int) throws -> [TrackRecord] {
        try base.searchTracks(profileId: profileId, query: query, limit: limit)
    }

    func recentlyAddedObservation(
        profileId: Int64,
        limit: Int
    ) -> ValueObservation<ValueReducers.Fetch<[TrackRecord]>> {
        base.recentlyAddedObservation(profileId: profileId, limit: limit)
    }
}
