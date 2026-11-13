// ArtworkService — the production ``ArtworkProviding`` that resolves cover art.
//
// Resolution order (each step falls through to the next on a miss):
//   1. EMBEDDED — art carried in the media file, read via the Metadata module's
//      ``MetadataReading``. Always tried first; needs no network.
//   2. COVER ART ARCHIVE — `https://coverartarchive.org/release/<mbid>/front`.
//      Requires a MusicBrainz release id; skipped when absent. A 404 (no cover
//      registered) falls through rather than failing.
//   3. iTUNES SEARCH — `https://itunes.apple.com/search?term=…&entity=album`,
//      then the album's `artworkUrl100` upgraded to a larger rendition.
//
// Steps 2–3 are OPT-IN: they run only when ``ArtworkRequest/allowsNetwork`` is
// true, so the default path is hermetic and the tests can prove ZERO network
// calls when network is disabled.
//
// The chosen bytes are downsampled to the requested rendition, content-hashed,
// and (optionally) written through to an ``ArtworkCache``. Foundation + Metadata
// only — no AppKit/UIKit.
import Foundation
import Metadata

/// Resolves cover art by consulting embedded art, then opt-in remote sources,
/// caching the winner. The production ``ArtworkProviding``.
public struct ArtworkService: ArtworkProviding {
    private let metadataReader: any MetadataReading
    private let network: any NetworkFetching
    private let cache: ArtworkCache?

    public init(
        metadataReader: any MetadataReading,
        network: any NetworkFetching = URLSessionNetworkFetcher(),
        cache: ArtworkCache? = nil
    ) {
        self.metadataReader = metadataReader
        self.network = network
        self.cache = cache
    }

    public func artwork(for request: ArtworkRequest) async throws -> ArtworkResult {
        if let cache, let hit = await cache.cachedArtwork(for: request.albumKey) {
            return hit
        }
        if let embedded = embeddedArtwork(for: request) {
            return try await finalize(data: embedded, source: .embedded, request: request)
        }
        guard request.allowsNetwork else { throw ArtworkError.notFound }

        if let archiveArt = try await coverArtArchive(for: request) {
            return try await finalize(data: archiveArt, source: .coverArtArchive, request: request)
        }
        if let itunesArt = try await itunesArtwork(for: request) {
            return try await finalize(data: itunesArt, source: .itunes, request: request)
        }
        throw ArtworkError.notFound
    }

    // MARK: Sources

    private func embeddedArtwork(for request: ArtworkRequest) -> Data? {
        guard let url = request.sourceURL else { return nil }
        guard let metadata = try? metadataReader.readMetadata(from: url) else { return nil }
        let pictures = metadata.artwork
        guard !pictures.isEmpty else { return nil }
        let chosen = pictures.first { $0.type == .frontCover } ?? pictures[0]
        return chosen.data.isEmpty ? nil : chosen.data
    }

    private func coverArtArchive(for request: ArtworkRequest) async throws -> Data? {
        guard let mbid = request.releaseMBID, !mbid.isEmpty else { return nil }
        guard var components = URLComponents(string: "https://coverartarchive.org") else { return nil }
        components.path = "/release/\(mbid)/front"
        guard let url = components.url else { return nil }
        let (data, status) = try await network.data(from: url)
        guard status == 200, !data.isEmpty else { return nil }
        return data
    }

    private func itunesArtwork(for request: ArtworkRequest) async throws -> Data? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        let term = "\(request.albumKey.artist) \(request.albumKey.album)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let searchURL = components.url else { return nil }
        let (json, status) = try await network.data(from: searchURL)
        guard status == 200, let artworkURL = Self.parseItunesArtworkURL(json) else { return nil }
        let (image, imageStatus) = try await network.data(from: artworkURL)
        guard imageStatus == 200, !image.isEmpty else { return nil }
        return image
    }

    /// Parses the iTunes Search response and upgrades the 100 px thumbnail URL to
    /// a 600 px rendition.
    static func parseItunesArtworkURL(_ data: Data) -> URL? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = root["results"] as? [[String: Any]],
            let first = results.first,
            let raw = first["artworkUrl100"] as? String
        else { return nil }
        let upgraded = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: upgraded)
    }

    // MARK: Finalize

    private func finalize(
        data: Data,
        source: ArtworkSource,
        request: ArtworkRequest
    ) async throws -> ArtworkResult {
        let processed = rendered(data, for: request.rendition)
        let result = ArtworkResult(
            data: processed,
            contentHash: ArtworkImageProcessing.contentHash(of: processed),
            source: source,
            pixelWidth: ArtworkImageProcessing.pixelSize(of: processed)?.width,
            pixelHeight: ArtworkImageProcessing.pixelSize(of: processed)?.height
        )
        if let cache {
            _ = try? await cache.store(result, for: request.albumKey)
        }
        return result
    }

    private func rendered(_ data: Data, for rendition: ArtworkRendition) -> Data {
        switch rendition {
        case let .thumbnail(maxPixel):
            (try? ArtworkImageProcessing.downsample(data, maxPixel: maxPixel)) ?? data
        case .full:
            data
        }
    }
}
