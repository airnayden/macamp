// Test doubles for the folder drag-reorder seam.
//
// Lives in its own file (rather than `ViewModelTestSupport.swift`) so the folder
// reorder work does not collide with concurrent edits to the shared support file.
import Foundation
import GRDB
import Persistence

/// One recorded `updateFolderPositions` call.
struct FolderOrderWrite: Equatable {
    let profileId: Int64
    let rootPath: String
    let orderedTrackIds: [Int64]
}

/// A ``TrackRepositoryProviding`` decorator that records every folder-order write.
///
/// Proves the negative half of the reorder gate: an All-Tracks or genre-filtered
/// drag must write NOTHING, which is only assertable by watching the repository.
final class FolderOrderSpyRepository: TrackRepositoryProviding, @unchecked Sendable {
    private let base: TrackRepository
    private let lock = NSLock()
    private var writes: [FolderOrderWrite] = []
    private var customPositionWrites = 0

    init(_ base: TrackRepository) {
        self.base = base
    }

    var folderOrderWrites: [FolderOrderWrite] {
        lock.withLock { writes }
    }

    var customPositionWriteCount: Int {
        lock.withLock { customPositionWrites }
    }

    func updateFolderPositions(
        profileId: Int64,
        rootPath: String,
        _ updates: [(trackId: Int64, position: Int)]
    ) async throws {
        lock.withLock {
            writes.append(FolderOrderWrite(
                profileId: profileId,
                rootPath: rootPath,
                orderedTrackIds: updates.sorted { $0.position < $1.position }.map(\.trackId)
            ))
        }
        try await base.updateFolderPositions(profileId: profileId, rootPath: rootPath, updates)
    }

    func updateCustomPositions(profileId: Int64, _ updates: [(trackId: Int64, position: Int)]) async throws {
        lock.withLock { customPositionWrites += 1 }
        try await base.updateCustomPositions(profileId: profileId, updates)
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
        try base.searchTracks(profileId: profileId, query: query, limit: limit)
    }

    func recentlyAddedObservation(
        profileId: Int64,
        limit: Int
    ) -> ValueObservation<ValueReducers.Fetch<[TrackRecord]>> {
        base.recentlyAddedObservation(profileId: profileId, limit: limit)
    }
}
