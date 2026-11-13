// Shared helpers + test doubles for the ViewModels suites.
//
// `pollUntil` lets an async @MainActor test wait for a `ValueObservation` /
// debounced / artwork task to deliver onto the main actor without sleeping a
// fixed duration. `CountingTrackRepository` proves debounce coalescing + window
// growth; `FakeSpectrumSource` feeds the visualizer pull path.
import Foundation
import GRDB
import Persistence
import Visualizer

/// Polls `condition` on the main actor until it holds or the timeout elapses.
@MainActor
func pollUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Builds a track record with a stable sort key derived from `title`.
func makeTrackRecord(
    filePath: String,
    title: String,
    artistName: String? = nil,
    availability: Availability = .present,
    dateAdded: Double = 0
) -> TrackRecord {
    TrackRecord(
        filePath: filePath,
        title: title,
        sortTitle: title.lowercased(),
        artistName: artistName,
        availability: availability,
        dateAdded: dateAdded
    )
}

/// A ``TrackRepositoryProviding`` decorator that counts `searchTracks` calls and
/// records the last limit — used to assert debounce coalescing + window growth.
final class CountingTrackRepository: TrackRepositoryProviding, @unchecked Sendable {
    private let base: TrackRepository
    private let lock = NSLock()
    private var searches = 0
    private var lastSearchLimit = 0

    init(_ base: TrackRepository) {
        self.base = base
    }

    var searchCount: Int {
        lock.withLock { searches }
    }

    var lastLimit: Int {
        lock.withLock { lastSearchLimit }
    }

    func fetchTrack(id: Int64) throws -> TrackRecord? {
        try base.fetchTrack(id: id)
    }

    func fetchTrack(filePath: String) throws -> TrackRecord? {
        try base.fetchTrack(filePath: filePath)
    }

    @discardableResult
    func insert(_ track: TrackRecord) throws -> TrackRecord {
        try base.insert(track)
    }

    func update(_ track: TrackRecord) throws {
        try base.update(track)
    }

    @discardableResult
    func deleteTrack(id: Int64) throws -> Bool {
        try base.deleteTrack(id: id)
    }

    @discardableResult
    func insertBatch(_ tracks: [TrackRecord]) throws -> Int {
        try base.insertBatch(tracks)
    }

    func tracksPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<TrackRecord, String> {
        try base.tracksPage(profileId: profileId, after: cursor, limit: limit)
    }

    func tracksPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) async throws -> Page<TrackRecord, String> {
        try await base.tracksPage(profileId: profileId, after: cursor, limit: limit)
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

    func searchTracks(profileId: Int64, query: String, limit: Int) throws -> [TrackRecord] {
        lock.withLock {
            searches += 1
            lastSearchLimit = limit
        }
        return try base.searchTracks(profileId: profileId, query: query, limit: limit)
    }

    func recentlyAddedObservation(
        profileId: Int64,
        limit: Int
    ) -> ValueObservation<ValueReducers.Fetch<[TrackRecord]>> {
        base.recentlyAddedObservation(profileId: profileId, limit: limit)
    }
}

/// A canned ``SpectrumSource`` returning fixed spectrum/waveform frames.
final class FakeSpectrumSource: SpectrumSource {
    private let spectrum: [Float]
    private let waveform: [Float]

    init(spectrum: [Float], waveform: [Float] = []) {
        self.spectrum = spectrum
        self.waveform = waveform
    }

    var bandCount: Int {
        spectrum.count
    }

    func latestSpectrum() -> [Float] {
        spectrum
    }

    func latestWaveform() -> [Float] {
        waveform
    }
}
