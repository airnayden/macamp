// YouTubeOEmbedClient — the SECOND of the two files in MacAMP's downloads surface
// that may construct a `URLSession`. `scripts/check-downloader-boundary.sh` exempts
// this path by name, alongside `DownloadToolReleaseClient.swift`, and nothing else.
//
// It is the transport half of `OEmbedFetching`, split out exactly the way
// `DownloadToolReleaseClient` is split out of `DownloadToolProviding`: the
// interesting half — request-URL construction, the status/decode policy, the
// concurrency window, the timeout budget — lives in PlayerCore
// (`Services/Downloads/YouTubeOEmbed.swift`) and is driven by tests with zero I/O.
// Everything here is bytes.
//
// ── THUMBNAILS RIDE THIS SAME TRANSPORT, ON PURPOSE ──────────────────────────
//
// The poster-frame bytes are fetched by `fetchThumbnail(url:)` HERE rather than by
// a `AsyncImage` somewhere in the view layer. An image view that fetches is a
// second egress path that no boundary guard can see and no consent copy describes,
// so the guard additionally refuses the `AsyncImage` token anywhere in this
// surface. One file transports.
//
// ── KEYLESS, AND NOTHING IS VERIFIED HERE ────────────────────────────────────
//
// oEmbed has no API key and none is used. This type verifies TRANSPORT ONLY: HTTPS
// (by construction for the lookup, by `validatedThumbnailURL` for the image), a
// bounded deadline, and an `OEmbedResponse` handed to the policy. Whether the
// answer counts at all — 2xx, decodable, non-empty title — is
// `YouTubeOEmbed.payload(from:)`'s decision, not this file's. Nothing here throws:
// a 404, a 401 on a private or deleted video, a timeout and a malformed body all
// arrive at the caller as the same silent `nil`, because this metadata is
// decorative and `-J` remains authoritative.
//
// No retries: a paste-time decoration that failed is simply not shown.
import Foundation
import Services

/// Reads YouTube's public oEmbed document, and poster-frame bytes, over HTTPS.
final class YouTubeOEmbedClient: OEmbedFetching {
    private let session: URLSession
    private let gate: OEmbedConcurrencyGate

    /// - Parameters:
    ///   - session: The transport. Defaults to ``makeSession()``.
    ///   - gate: The ≤4 window. Injectable so a test can narrow or widen it; the
    ///     default is the policy's own ``YouTubeOEmbed/maximumConcurrentFetches``.
    init(
        session: URLSession = YouTubeOEmbedClient.makeSession(),
        gate: OEmbedConcurrencyGate = OEmbedConcurrencyGate()
    ) {
        self.session = session
        self.gate = gate
    }

    /// A session that keeps nothing and waits five seconds at most.
    ///
    /// Ephemeral with cookies refused: an anonymous read of a public endpoint must
    /// not carry, or accumulate, any credential. BOTH timeouts are the policy's
    /// budget — bounding the request alone would let a trickling response hold a
    /// permit open indefinitely, which is the one thing
    /// ``OEmbedConcurrencyGate``'s no-deadlock argument depends on not happening.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = YouTubeOEmbed.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = YouTubeOEmbed.requestTimeoutSeconds
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = YouTubeOEmbed.maximumConcurrentFetches
        return URLSession(configuration: configuration)
    }

    // MARK: - OEmbedFetching

    func fetch(videoID: String) async -> OEmbedPayload? {
        guard let url = YouTubeOEmbed.requestURL(forVideoID: videoID) else { return nil }
        let response = await gate.withPermit { await self.send(url, accept: Self.jsonAccept) }
        return YouTubeOEmbed.payload(from: response)
    }

    func fetchThumbnail(url: URL) async -> Data? {
        guard let validated = YouTubeOEmbed.validatedThumbnailURL(url) else { return nil }
        let response = await gate.withPermit { await self.send(validated, accept: Self.imageAccept) }
        return YouTubeOEmbed.thumbnailData(from: response)
    }

    // MARK: - Transport

    private static let jsonAccept = "application/json"
    private static let imageAccept = "image/*"
    private static let userAgent = "MacAMP"

    /// One round-trip with every failure — timeout, DNS, TLS, offline, a response
    /// that is not HTTP — flattened to `nil`. The status is NOT judged here.
    private func send(_ url: URL, accept: String) async -> OEmbedResponse? {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return OEmbedResponse(statusCode: http.statusCode, body: data)
    }
}
