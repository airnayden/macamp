import Foundation

/// Requested rendition of cover art.
///
/// List UIs ask for a downsampled ``thumbnail(maxPixel:)`` so they never decode
/// full-resolution images, while the now-playing screen asks for ``full``.
public enum ArtworkRendition: Sendable, Hashable {
    /// Downsampled image whose longest edge is at most `maxPixel` pixels.
    case thumbnail(maxPixel: Int)
    /// Full-size image for now-playing display.
    case full
}

/// The origin of resolved cover art, in resolution-priority order.
public enum ArtworkSource: String, Sendable, Hashable, Codable {
    /// Art embedded in the media file (read via the Metadata module).
    case embedded
    /// Art fetched from the Cover Art Archive (`coverartarchive.org`).
    case coverArtArchive
    /// Art fetched from the iTunes Search API (`itunes.apple.com`).
    case itunes
    /// Art served from the local on-disk cache.
    case cache
}

/// A request to resolve cover art for a track or album.
public struct ArtworkRequest: Sendable, Hashable {
    /// Album-level identity used for cache keying and per-album dedupe.
    public struct AlbumKey: Sendable, Hashable, Codable {
        public var artist: String
        public var album: String

        public init(artist: String, album: String) {
            self.artist = artist
            self.album = album
        }
    }

    /// Album/artist used for remote lookup and cache keying.
    public var albumKey: AlbumKey
    /// Local media file that may carry embedded artwork.
    public var sourceURL: URL?
    /// Optional MusicBrainz release id used to query the Cover Art Archive directly.
    public var releaseMBID: String?
    /// Desired rendition (thumbnail for lists, full for now-playing).
    public var rendition: ArtworkRendition
    /// Whether remote fetch (CAA / iTunes) is permitted. Network is opt-in.
    public var allowsNetwork: Bool

    public init(
        albumKey: AlbumKey,
        sourceURL: URL? = nil,
        releaseMBID: String? = nil,
        rendition: ArtworkRendition = .full,
        allowsNetwork: Bool = false
    ) {
        self.albumKey = albumKey
        self.sourceURL = sourceURL
        self.releaseMBID = releaseMBID
        self.rendition = rendition
        self.allowsNetwork = allowsNetwork
    }
}

/// Resolved cover art plus provenance and dedupe metadata.
public struct ArtworkResult: Sendable, Hashable {
    /// Encoded image bytes (PNG or JPEG).
    public var data: Data
    /// Lowercase-hex SHA-256 of ``data`` used for content-addressed dedupe.
    public var contentHash: String
    /// Where the art came from.
    public var source: ArtworkSource
    /// Decoded pixel width, when known.
    public var pixelWidth: Int?
    /// Decoded pixel height, when known.
    public var pixelHeight: Int?

    public init(
        data: Data,
        contentHash: String,
        source: ArtworkSource,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.data = data
        self.contentHash = contentHash
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Errors surfaced by artwork resolution.
public enum ArtworkError: Error, Sendable, Equatable {
    /// No artwork could be found in any source.
    case notFound
    /// A remote source was required but ``ArtworkRequest/allowsNetwork`` was false.
    case networkDisabled
    /// A remote source returned a non-success HTTP status.
    case httpStatus(Int)
    /// Image bytes could not be decoded or downsampled.
    case decodeFailed
    /// The operation was cancelled.
    case cancelled
}

/// Resolves cover art for a request.
///
/// Implementations consult embedded art first, then opt-in remote sources, and
/// finally cache results. See ``ArtworkService``.
public protocol ArtworkProviding: Sendable {
    /// Resolve cover art for `request`, throwing ``ArtworkError`` on failure.
    func artwork(for request: ArtworkRequest) async throws -> ArtworkResult
}

/// In-memory ``ArtworkProviding`` for tests and previews.
///
/// Records every request and returns canned results keyed by album. It performs
/// no I/O and never touches the network.
public actor FakeArtworkProvider: ArtworkProviding {
    /// Canned results keyed by album.
    public var responses: [ArtworkRequest.AlbumKey: ArtworkResult]
    /// When set, every call throws this instead of returning a response.
    public var error: ArtworkError?
    /// Every request received, in call order.
    public private(set) var requests: [ArtworkRequest] = []

    public init(
        responses: [ArtworkRequest.AlbumKey: ArtworkResult] = [:],
        error: ArtworkError? = nil
    ) {
        self.responses = responses
        self.error = error
    }

    /// Register a canned result for an album.
    public func setResponse(_ result: ArtworkResult, for key: ArtworkRequest.AlbumKey) {
        responses[key] = result
    }

    public func artwork(for request: ArtworkRequest) async throws -> ArtworkResult {
        requests.append(request)
        if let error { throw error }
        guard let result = responses[request.albumKey] else { throw ArtworkError.notFound }
        return result
    }
}
