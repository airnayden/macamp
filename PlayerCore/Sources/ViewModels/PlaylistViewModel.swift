// PlaylistViewModel — the tested seam between the playlist Persistence layer and
// the macOS / iOS playlist UIs (Tasks 18–20).
//
// Listing playlists (with track counts) and a playlist's tracks are BOTH
// keyset-paginated (`PlaylistRepository.playlistsWithTrackCounts` /
// `playlistTracksPage`); the whole library / playlist is never loaded into memory
// (PlayerCore memory invariant, 100k tracks / 50k-entry playlists).
//
// Every database touch runs OFF the main actor: the repository's `async`
// overloads suspend on a GRDB reader/writer (`try await dbWriter.read/write`)
// rather than parking the `@MainActor` thread on a pooled connection — the
// priority-inversion / "hang risk" Task 3 removed from `LibraryViewModel`.
//
// State changes use the `@Observable` macro (the playlist UIs are SwiftUI shells
// and already require the Xcode toolchain). This file imports only Foundation +
// Observation + Persistence; it MUST NOT import AppKit or UIKit (PlayerCore
// portability invariant).
import Foundation
import Observation
import Persistence

/// Browses playlists (keyset-paginated, with track counts) and edits a playlist's
/// ordered membership — all without ever blocking the main actor on the database.
@MainActor
@Observable
public final class PlaylistViewModel {
    /// Accumulated keyset pages of playlists, each with its track count.
    public private(set) var playlists: [PlaylistWithTrackCount] = []
    /// Accumulated keyset pages of the selected playlist's ordered tracks.
    public private(set) var tracks: [PlaylistTrackItem] = []
    /// `true` while a playlist page is being fetched.
    public private(set) var isLoadingPlaylists = false
    /// `false` once the last playlist page has been loaded.
    public private(set) var hasMorePlaylists = true
    /// `true` while a track page is being fetched.
    public private(set) var isLoadingTracks = false
    /// `false` once the last track page has been loaded.
    public private(set) var hasMoreTracks = true

    @ObservationIgnored private let repository: any PlaylistRepositoryProviding
    @ObservationIgnored private let pageSize: Int

    @ObservationIgnored private var playlistCursor: PageCursor<String>?
    @ObservationIgnored private var trackCursor: PageCursor<Int>?

    /// The profile whose playlists this view model is scoped to (Guest `1` by
    /// default). Set at construction from the active profile and re-assigned by the
    /// profile-switch seam (Task 11); scoped repository reads pass it (Task 12).
    @ObservationIgnored public var activeProfileId: Int64

    /// Creates a playlist view model over an injected repository.
    ///
    /// - Parameters:
    ///   - repository: Source of paginated playlists/tracks + membership writes.
    ///   - pageSize: Rows per keyset page.
    ///   - activeProfileId: The profile to scope reads to (Guest `1` by default).
    public init(
        repository: any PlaylistRepositoryProviding,
        pageSize: Int = 100,
        activeProfileId: Int64 = 1
    ) {
        self.repository = repository
        self.pageSize = max(1, pageSize)
        self.activeProfileId = activeProfileId
    }
}

// MARK: - Playlist list (keyset pagination)

public extension PlaylistViewModel {
    /// Loads (or reloads) the first keyset page of playlists.
    func loadInitialPlaylists() async throws {
        isLoadingPlaylists = true
        defer { isLoadingPlaylists = false }
        let page = try await repository.playlistsWithTrackCounts(
            profileId: activeProfileId,
            after: nil,
            limit: pageSize
        )
        playlists = page.items
        playlistCursor = page.nextCursor
        hasMorePlaylists = page.nextCursor != nil
    }

    /// Appends the next keyset page of playlists (with track counts), if any.
    func loadMorePlaylists() async throws {
        guard hasMorePlaylists, !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        defer { isLoadingPlaylists = false }
        let page = try await repository.playlistsWithTrackCounts(
            profileId: activeProfileId,
            after: playlistCursor,
            limit: pageSize
        )
        playlists.append(contentsOf: page.items)
        playlistCursor = page.nextCursor
        hasMorePlaylists = page.nextCursor != nil
    }
}

// MARK: - Playlist tracks (keyset pagination)

public extension PlaylistViewModel {
    /// Loads (or reloads) the first keyset page of a playlist's tracks.
    func loadInitialTracks(in playlistId: Int64) async throws {
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        let page = try await repository.playlistTracksPage(playlistId: playlistId, after: nil, limit: pageSize)
        guard !Task.isCancelled else { return }
        tracks = page.items
        trackCursor = page.nextCursor
        hasMoreTracks = page.nextCursor != nil
    }

    /// Appends the next keyset page of a playlist's tracks, if any.
    func loadMoreTracks(in playlistId: Int64) async throws {
        guard hasMoreTracks, !isLoadingTracks else { return }
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        let page = try await repository.playlistTracksPage(
            playlistId: playlistId,
            after: trackCursor,
            limit: pageSize
        )
        tracks.append(contentsOf: page.items)
        trackCursor = page.nextCursor
        hasMoreTracks = page.nextCursor != nil
    }
}

// MARK: - Load a playlist's tracks

public extension PlaylistViewModel {
    /// Loads the first keyset page of a playlist's ordered membership.
    func loadTracks(for playlist: PlaylistRecord) async throws {
        guard let playlistId = playlist.id else { return }
        try await loadInitialTracks(in: playlistId)
    }
}

// MARK: - Mutations

public extension PlaylistViewModel {
    /// Creates a new playlist owned by the active profile and returns the inserted record.
    @discardableResult
    func createPlaylist(named name: String) async throws -> PlaylistRecord {
        try await repository.create(named: name, profileId: activeProfileId)
    }

    /// Renames a playlist (keeps its id).
    func renamePlaylist(_ playlist: PlaylistRecord, to newName: String) async throws {
        var updated = playlist
        updated.name = newName
        try await repository.update(updated)
    }

    /// Deletes a playlist (its memberships cascade); returns whether a row was removed.
    @discardableResult
    func deletePlaylist(id: Int64) async throws -> Bool {
        try await repository.deletePlaylist(id: id)
    }

    /// Appends a track to the end of a playlist.
    func addTrack(_ trackId: Int64, toPlaylist playlistId: Int64) async throws {
        try await repository.addTrack(trackId: trackId, toPlaylist: playlistId)
    }

    /// Removes a track from a playlist.
    func removeTrack(_ trackId: Int64, fromPlaylist playlistId: Int64) async throws {
        try await repository.removeTrack(trackId: trackId, fromPlaylist: playlistId)
    }

    /// Atomically rewrites a playlist's order to `orderedTrackIds`.
    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
    }

    func reorderTracks(in playlistId: Int64, orderedTrackIds: [Int64]) async throws {
        try await repository.reorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
    }
}
