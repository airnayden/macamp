// LibraryViewModel — the tested seam between the library Persistence layer and
// the macOS / iOS list UIs (Tasks 25–35).
//
// Browsing is keyset-paginated (`TrackRepository.tracksPage` / `albumsPage` /
// `artistsPage`); reactive "recently added" uses a BOUNDED `ValueObservation`
// (`.immediate` scheduling, `LIMIT`-capped) so the observation never loads the
// whole `track` table — observing an unfiltered table is forbidden at a 100k-row
// scale (PlayerCore memory invariant).
//
// State changes use the `@Observable` macro (Tasks 25–35 are SwiftUI shells and
// already require the Xcode toolchain), unlike the engine/coordinator layers
// which kept a hand-rolled callback to stay toolchain-free.
//
// This file imports only Foundation + GRDB + Observation + Persistence; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import GRDB
import Observation
import Persistence

/// A list badge describing a track's backing-file availability.
public enum AvailabilityBadge: String, Sendable, Equatable {
    /// The file is present and playable now.
    case available
    /// The file used to exist but can no longer be found.
    case missing
    /// The file lives on an external volume that is not currently mounted.
    case offline
}

/// Browses the library (tracks / albums / artists) with windowed queries and
/// exposes a bounded, reactive `recentlyAdded` snapshot.
@MainActor
@Observable
public final class LibraryViewModel {
    /// Accumulated keyset pages of tracks, ordered by `(sortTitle, id)`.
    public private(set) var tracks: [TrackRecord] = []
    /// Accumulated keyset pages of albums.
    public private(set) var albums: [AlbumRecord] = []
    /// Accumulated keyset pages of artists.
    public private(set) var artists: [ArtistRecord] = []
    /// The bounded, reactive most-recently-added window.
    public private(set) var recentlyAdded: [TrackRecord] = []
    /// `true` while a track page is being fetched.
    public private(set) var isLoadingTracks = false
    /// `false` once the last track page has been loaded.
    public private(set) var hasMoreTracks = true
    /// The last observation error, if any (localized description).
    public private(set) var observationError: String?

    @ObservationIgnored private let trackRepository: any TrackRepositoryProviding
    @ObservationIgnored private let albumRepository: any AlbumRepositoryProviding
    @ObservationIgnored private let artistRepository: any ArtistRepositoryProviding
    @ObservationIgnored private let databaseReader: any DatabaseReader
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let recentLimit: Int

    @ObservationIgnored private var trackCursor: PageCursor<String>?
    @ObservationIgnored private var albumCursor: PageCursor<String>?
    @ObservationIgnored private var artistCursor: PageCursor<String>?
    @ObservationIgnored private var recentlyAddedCancellable: AnyDatabaseCancellable?

    /// The profile whose library this view model is scoped to (Guest `1` by
    /// default). Set at construction from the active profile and re-assigned by the
    /// profile-switch seam (Task 11); scoped repository reads pass it (Task 7).
    @ObservationIgnored public var activeProfileId: Int64

    /// Creates a library view model over injected repositories + a reader.
    ///
    /// - Parameters:
    ///   - trackRepository: Source of paginated tracks + the bounded observation.
    ///   - albumRepository: Source of paginated albums.
    ///   - artistRepository: Source of paginated artists.
    ///   - databaseReader: The reader the `recentlyAdded` observation starts on
    ///     (an `AppDatabase.writer` is also a reader).
    ///   - pageSize: Rows per keyset page.
    ///   - recentLimit: Cap for the bounded `recentlyAdded` observation.
    ///   - activeProfileId: The profile to scope reads to (Guest `1` by default).
    public init(
        trackRepository: any TrackRepositoryProviding,
        albumRepository: any AlbumRepositoryProviding,
        artistRepository: any ArtistRepositoryProviding,
        databaseReader: any DatabaseReader,
        pageSize: Int = 100,
        recentLimit: Int = 50,
        activeProfileId: Int64 = 1
    ) {
        self.trackRepository = trackRepository
        self.albumRepository = albumRepository
        self.artistRepository = artistRepository
        self.databaseReader = databaseReader
        self.pageSize = max(1, pageSize)
        self.recentLimit = max(1, recentLimit)
        self.activeProfileId = activeProfileId
    }

    /// Maps a track's availability to a list badge.
    public func badge(for track: TrackRecord) -> AvailabilityBadge {
        switch track.availability {
        case .present: .available
        case .missing: .missing
        case .externalOffline: .offline
        }
    }
}

// MARK: - Bounded recently-added observation

public extension LibraryViewModel {
    /// Starts the bounded `recentlyAdded` observation (`.immediate` scheduling).
    ///
    /// The underlying request is `LIMIT`-capped, so the observation never loads
    /// the whole `track` table. The first value is delivered synchronously on the
    /// main actor; later values arrive asynchronously on the main actor. The
    /// returned cancellable is retained and auto-cancels when this model is
    /// deallocated (no manual `deinit` needed; no retain cycle — `onChange`
    /// captures `self` weakly).
    func startObservingRecentlyAdded() {
        guard recentlyAddedCancellable == nil else { return }
        recentlyAddedCancellable = trackRepository
            .recentlyAddedObservation(profileId: activeProfileId, limit: recentLimit)
            .start(
                in: databaseReader,
                scheduling: .immediate,
                onError: { [weak self] error in
                    self?.observationError = error.localizedDescription
                },
                onChange: { [weak self] records in
                    self?.recentlyAdded = records
                }
            )
    }

    /// Cancels the `recentlyAdded` observation, if any.
    func stopObservingRecentlyAdded() {
        recentlyAddedCancellable?.cancel()
        recentlyAddedCancellable = nil
    }
}

// MARK: - Keyset pagination

public extension LibraryViewModel {
    /// Loads (or reloads) the first keyset page, replacing `tracks` atomically.
    ///
    /// Must not clear `tracks` first nor route through `loadMoreTracks`: that let a
    /// concurrent caller wipe `tracks` then early-return on the `isLoadingTracks`
    /// guard (a `.task(id:)` reload cancelled by a view rebuild), leaving it empty.
    func loadInitialTracks() async throws {
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        let page = try await trackRepository.tracksPage(profileId: activeProfileId, after: nil, limit: pageSize)
        tracks = page.items
        trackCursor = page.nextCursor
        hasMoreTracks = page.nextCursor != nil
    }

    /// Appends the next keyset page of tracks, if any.
    func loadMoreTracks() async throws {
        guard hasMoreTracks, !isLoadingTracks else { return }
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        let page = try await trackRepository.tracksPage(profileId: activeProfileId, after: trackCursor, limit: pageSize)
        tracks.append(contentsOf: page.items)
        trackCursor = page.nextCursor
        hasMoreTracks = page.nextCursor != nil
    }

    /// Loads (or reloads) the first keyset page of albums.
    func loadInitialAlbums() async throws {
        let page = try await albumRepository.albumsPage(after: nil, limit: pageSize)
        albums = page.items
        albumCursor = page.nextCursor
    }

    /// Appends the next keyset page of albums, if any.
    func loadMoreAlbums() async throws {
        let page = try await albumRepository.albumsPage(after: albumCursor, limit: pageSize)
        albums.append(contentsOf: page.items)
        albumCursor = page.nextCursor
    }

    /// Loads (or reloads) the first keyset page of artists.
    func loadInitialArtists() async throws {
        let page = try await artistRepository.artistsPage(after: nil, limit: pageSize)
        artists = page.items
        artistCursor = page.nextCursor
    }

    /// Appends the next keyset page of artists, if any.
    func loadMoreArtists() async throws {
        let page = try await artistRepository.artistsPage(after: artistCursor, limit: pageSize)
        artists.append(contentsOf: page.items)
        artistCursor = page.nextCursor
    }
}
