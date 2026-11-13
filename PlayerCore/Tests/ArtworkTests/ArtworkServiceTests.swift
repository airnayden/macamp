@testable import Artwork
import Foundation
import Metadata
import Testing

@Suite("ArtworkServiceTests")
struct ArtworkServiceTests {
    private static let album = ArtworkRequest.AlbumKey(artist: "Daft Punk", album: "Discovery")
    private static let sourceURL = URL(fileURLWithPath: "/tmp/track.flac")
    private static let imageBytes = Data(repeating: 0xAB, count: 512)

    /// iTunes Search response whose `artworkUrl100` upgrades to a 600 px URL on a
    /// host the fake fetcher recognises.
    private static func itunesSearchJSON() throws -> Data {
        let payload: [String: Any] = [
            "resultCount": 1,
            "results": [["artworkUrl100": "https://art.example.com/cover/100x100bb.jpg"]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func cascadingFetcher() throws -> RecordingNetworkFetcher {
        let json = try itunesSearchJSON()
        let bytes = imageBytes
        return RecordingNetworkFetcher { url in
            if url.host == "coverartarchive.org" {
                return (Data(), 404) // no cover registered → fall through to iTunes
            }
            if url.absoluteString.contains("itunes.apple.com/search") {
                return (json, 200)
            }
            if url.host == "art.example.com" {
                return (bytes, 200)
            }
            return (Data(), 404)
        }
    }

    @Test("resolves in order embedded → CAA → iTunes, recording each remote URL")
    func resolutionOrder() async throws {
        let reader = FakeMetadataReader(metadata: TrackMetadata(artist: "Daft Punk", album: "Discovery"))
        let fetcher = try Self.cascadingFetcher()
        let service = ArtworkService(metadataReader: reader, network: fetcher)
        let request = ArtworkRequest(
            albumKey: Self.album,
            sourceURL: Self.sourceURL,
            releaseMBID: "11111111-2222-3333-4444-555555555555",
            allowsNetwork: true
        )

        let result = try await service.artwork(for: request)
        let urls = await fetcher.requestedURLs

        #expect(result.source == .itunes)
        #expect(result.data == Self.imageBytes)
        #expect(result.contentHash.count == 64)

        #expect(urls.count == 3)
        #expect(urls[0].host == "coverartarchive.org")
        #expect(urls[0].path == "/release/11111111-2222-3333-4444-555555555555/front")
        #expect(urls[1].absoluteString.contains("itunes.apple.com/search"))
        #expect(urls[2].host == "art.example.com")
        #expect(urls[2].absoluteString.contains("600x600bb"))
    }

    @Test("embedded art short-circuits before any network call")
    func embeddedShortCircuitsNetwork() async throws {
        let art = EmbeddedArtwork(data: Data([0xFF, 0xD8, 0xFF, 0x01]), mimeType: "image/jpeg", type: .frontCover)
        let reader = FakeMetadataReader(
            metadata: TrackMetadata(artist: "Daft Punk", album: "Discovery", artwork: [art])
        )
        let fetcher = try Self.cascadingFetcher()
        let service = ArtworkService(metadataReader: reader, network: fetcher)
        let request = ArtworkRequest(
            albumKey: Self.album,
            sourceURL: Self.sourceURL,
            releaseMBID: "11111111-2222-3333-4444-555555555555",
            allowsNetwork: true
        )

        let result = try await service.artwork(for: request)
        let urls = await fetcher.requestedURLs

        #expect(result.source == .embedded)
        #expect(result.data == art.data)
        #expect(urls.isEmpty)
    }

    @Test("allowsNetwork == false performs ZERO network calls")
    func networkDisabledMakesNoCalls() async throws {
        let reader = FakeMetadataReader(metadata: TrackMetadata(artist: "Daft Punk", album: "Discovery"))
        let fetcher = try Self.cascadingFetcher()
        let service = ArtworkService(metadataReader: reader, network: fetcher)
        let request = ArtworkRequest(
            albumKey: Self.album,
            sourceURL: Self.sourceURL,
            releaseMBID: "11111111-2222-3333-4444-555555555555",
            allowsNetwork: false
        )

        await #expect(throws: ArtworkError.notFound) {
            _ = try await service.artwork(for: request)
        }
        let urls = await fetcher.requestedURLs
        #expect(urls.isEmpty)
    }

    @Test("iTunes artwork URL parses and upgrades to 600 px")
    func parsesItunesArtworkURL() throws {
        let json = try Self.itunesSearchJSON()
        let url = try #require(ArtworkService.parseItunesArtworkURL(json))
        #expect(url.absoluteString == "https://art.example.com/cover/600x600bb.jpg")
    }
}
