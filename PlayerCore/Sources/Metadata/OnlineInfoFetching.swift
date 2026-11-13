// OnlineInfoFetching — the online narrative-info seam + its result value types.
//
// The "rich info" analogue of ``OnlineMetadataFetching``: where that seam resolves
// the structured tag fields (title/artist/album/year/…), this one resolves the
// human-readable NARRATIVE about an entity — an artist biography, an album story,
// a track description — plus a few descriptive tags. Production code uses
// ``MusicBrainzInfoClient`` (MusicBrainz `url-rels` → Wikipedia REST summary);
// tests and previews use ``MockInfoFetcher`` so **no live network request is ever
// made off the production path**.
//
// The provider protocol means the backend can be swapped later (e.g. a Last.fm
// implementation) without touching the cache, service, or UI layers.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

// MARK: - Result value types

/// Narrative info about an artist (its biography, descriptive tags, an image).
///
/// `Codable` so ``InfoCacheStore`` can JSON-encode it into the `infoCache` table;
/// `Sendable` so it can cross actor/`async` boundaries freely.
public struct ArtistInfo: Sendable, Codable, Equatable {
    /// A prose biography (typically the Wikipedia summary extract).
    public var biography: String?
    /// Descriptive folksonomy tags / genres, highest-weighted first.
    public var tags: [String]
    /// A representative image (e.g. the Wikipedia page thumbnail).
    public var imageURL: URL?

    public init(biography: String? = nil, tags: [String] = [], imageURL: URL? = nil) {
        self.biography = biography
        self.tags = tags
        self.imageURL = imageURL
    }

    /// `true` when there is nothing worth displaying.
    public var isEmpty: Bool {
        (biography?.isEmpty ?? true) && tags.isEmpty && imageURL == nil
    }
}

/// Narrative info about an album / release (its story, tags, release date).
public struct AlbumInfo: Sendable, Codable, Equatable {
    /// A prose description (typically the Wikipedia summary extract).
    public var description: String?
    /// Descriptive folksonomy tags / genres, highest-weighted first.
    public var tags: [String]
    /// The first-release date as MusicBrainz reports it (`"1973"`, `"1973-03-01"`).
    public var releaseDate: String?

    public init(description: String? = nil, tags: [String] = [], releaseDate: String? = nil) {
        self.description = description
        self.tags = tags
        self.releaseDate = releaseDate
    }

    /// `true` when there is nothing worth displaying.
    public var isEmpty: Bool {
        (description?.isEmpty ?? true) && tags.isEmpty && (releaseDate?.isEmpty ?? true)
    }
}

/// Narrative info about a single track / recording (its description, tags).
public struct TrackInfo: Sendable, Codable, Equatable {
    /// A prose description (typically the Wikipedia summary extract, when one exists).
    public var description: String?
    /// Descriptive folksonomy tags / genres, highest-weighted first.
    public var tags: [String]

    public init(description: String? = nil, tags: [String] = []) {
        self.description = description
        self.tags = tags
    }

    /// `true` when there is nothing worth displaying.
    public var isEmpty: Bool {
        (description?.isEmpty ?? true) && tags.isEmpty
    }
}

// MARK: - Fetch protocol

/// Resolves narrative info for an artist / album / track from an online source.
///
/// Production uses ``MusicBrainzInfoClient``; tests/previews use ``MockInfoFetcher``
/// so no live network call is made off the production path. The protocol is the
/// swap point for a future alternative backend (Last.fm, Discogs, …).
public protocol OnlineInfoFetching: Sendable {
    /// Resolves info for an artist, optionally short-circuiting on a known MBID.
    ///
    /// - Returns: the info, or `nil` when nothing can be resolved.
    /// - Throws: a transport / decoding error — never for a plain "no match".
    func fetchArtistInfo(name: String, mbid: String?) async throws -> ArtistInfo?

    /// Resolves info for an album / release group.
    ///
    /// - Returns: the info, or `nil` when nothing can be resolved.
    /// - Throws: a transport / decoding error — never for a plain "no match".
    func fetchAlbumInfo(title: String, artist: String?, mbid: String?) async throws -> AlbumInfo?

    /// Resolves info for a single track / recording.
    ///
    /// - Returns: the info, or `nil` when nothing can be resolved.
    /// - Throws: a transport / decoding error — never for a plain "no match".
    func fetchTrackInfo(title: String, artist: String?, mbid: String?) async throws -> TrackInfo?
}

// MARK: - Mock (tests + previews)

/// A canned ``OnlineInfoFetching`` that records its queries and never hits the
/// network. Thread-safe (an `NSLock` guards the recorded queries), hence
/// `@unchecked Sendable`. Mirrors ``MockMetadataFetcher`` on the metadata side and
/// is shipped (not test-only) so the macOS/iOS preview composition roots can inject
/// it without linking the test-support library.
public final class MockInfoFetcher: OnlineInfoFetching, @unchecked Sendable {
    /// One recorded query, captured verbatim (entity + identifying fields).
    public struct Query: Sendable, Equatable {
        public let kind: String
        public let name: String
        public let secondary: String?
        public let mbid: String?

        public init(kind: String, name: String, secondary: String?, mbid: String?) {
            self.kind = kind
            self.name = name
            self.secondary = secondary
            self.mbid = mbid
        }
    }

    private let lock = NSLock()
    private let artist: ArtistInfo?
    private let album: AlbumInfo?
    private let track: TrackInfo?
    private var recorded: [Query] = []

    /// Creates a mock returning the given canned values (each defaults to `nil`).
    public init(artist: ArtistInfo? = nil, album: AlbumInfo? = nil, track: TrackInfo? = nil) {
        self.artist = artist
        self.album = album
        self.track = track
    }

    /// Every query this mock was asked to resolve, in call order.
    public var queries: [Query] {
        lock.withLock { recorded }
    }

    public func fetchArtistInfo(name: String, mbid: String?) async throws -> ArtistInfo? {
        lock.withLock { recorded.append(Query(kind: "artist", name: name, secondary: nil, mbid: mbid)) }
        return artist
    }

    public func fetchAlbumInfo(title: String, artist: String?, mbid: String?) async throws -> AlbumInfo? {
        lock.withLock { recorded.append(Query(kind: "album", name: title, secondary: artist, mbid: mbid)) }
        return album
    }

    public func fetchTrackInfo(title: String, artist: String?, mbid: String?) async throws -> TrackInfo? {
        lock.withLock { recorded.append(Query(kind: "track", name: title, secondary: artist, mbid: mbid)) }
        return track
    }
}
