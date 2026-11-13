// YouTubeLinkResolver+Search — the two search branches and the oEmbed check.
//
// A separate FILE, not a separate type: SwiftLint's 400-line `file_length` ceiling
// is a hard one at `--strict`, and the same split already exists for the
// connectors (`OllamaConnector+ToolLoop.swift`). Everything here is `private` to
// this file except what the primary file already declared.
//
// ── ONLY "200 + PARSEABLE JSON" VERIFIES ───────────────────────────────────────
//
// The published oEmbed status taxonomy for a missing or private video is not
// stable enough to branch on — 400, 401 and 404 have all been reported for the
// same class of failure, and a plain-text "Forbidden" has been observed carrying a
// 200. So this file branches on exactly one thing: a 200 whose body decodes into a
// non-empty `title`. Everything else is unresolved. That is why no status constant
// other than 200 appears below, and why a decode failure is not distinguished from
// a network failure — both mean "no verified link", which is the only outcome the
// caller can act on.
//
// Nothing here throws: a resolve either produces a verified link or `nil`.
import Foundation

extension YouTubeLinkResolver {
    private static let dataAPIHost = "www.googleapis.com"
    private static let dataAPIPath = "/youtube/v3/search"
    private static let oEmbedPath = "/oembed"
    private static let searchEndpoint = "https://api.tavily.com/search"
    private static let searchDomain = "youtube.com"
    private static let accessModeHeaderField = "X-Tavily-Access-Mode"
    private static let keylessAccessMode = "keyless"
    private static let authorizationHeaderField = "Authorization"
    private static let contentTypeHeaderField = "Content-Type"
    private static let jsonContentType = "application/json"
    private static let verifiedStatusCode = 200
    private static let keyedResultCount = 3
    private static let keylessResultCount = 5

    /// RFC 3986 unreserved. Encoding against this set — and nothing wider — is what
    /// turns the inner watch URL into ONE opaque query value.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// `.sortedKeys` keeps the request body byte-stable, so a recorded-request
    /// assertion can compare exact JSON instead of re-parsing it.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: - Search

    /// Keyed when a YouTube key is configured, keyless otherwise.
    ///
    /// Deliberately NOT a fallback chain: one search provider per lookup keeps the
    /// egress predictable and matches what the consent copy promises.
    func searchForCandidate(_ request: Request) async -> URL? {
        if let key = await resolvedKey(youTubeAPIKey) {
            return await keyedCandidate(for: request, key: key)
        }
        return await keylessCandidate(for: request)
    }

    /// The YouTube Data API v3 branch. Scripted-transport tested only — see the
    /// primary file's header.
    private func keyedCandidate(for request: Request, key: String) async -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.dataAPIHost
        components.path = Self.dataAPIPath
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "q", value: request.searchQuery),
            URLQueryItem(name: "maxResults", value: String(Self.keyedResultCount)),
            URLQueryItem(name: "key", value: key),
        ]
        guard let url = components.url,
              let response = await send(URLRequest(url: url)), response.isSuccess,
              let payload = try? JSONDecoder().decode(DataAPISearchPayload.self, from: response.body)
        else { return nil }
        let candidates = payload.items.compactMap(\.id.videoId).compactMap(Self.watchURL(forVideoID:))
        return Self.firstValidWatchURL(in: candidates)
    }

    /// The keyless branch: a search scoped to youtube.com, so every hit is already
    /// a YouTube URL and only the SHAPE still has to be proven. A hit that is a
    /// channel or a playlist fails the gate and the next candidate is tried.
    private func keylessCandidate(for request: Request) async -> URL? {
        guard let url = URL(string: Self.searchEndpoint) else { return nil }
        let query = SearchQuery(
            query: request.searchQuery,
            maxResults: Self.keylessResultCount,
            includeDomains: [Self.searchDomain]
        )
        guard let body = try? Self.encoder.encode(query) else { return nil }
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.httpBody = body
        httpRequest.setValue(Self.jsonContentType, forHTTPHeaderField: Self.contentTypeHeaderField)
        if let key = await resolvedKey(searchAPIKey) {
            httpRequest.setValue("Bearer \(key)", forHTTPHeaderField: Self.authorizationHeaderField)
        } else {
            httpRequest.setValue(Self.keylessAccessMode, forHTTPHeaderField: Self.accessModeHeaderField)
        }
        guard let response = await send(httpRequest), response.isSuccess,
              let payload = try? JSONDecoder().decode(SearchPayload.self, from: response.body)
        else { return nil }
        return Self.firstValidWatchURL(in: payload.results.compactMap(\.url).compactMap(URL.init(string:)))
    }

    // MARK: - Verification

    /// Confirms a candidate exists and matches, or answers `nil`.
    ///
    /// Written as one pipeline on purpose: every step is a reason to give up, and
    /// the only exit that produces a link is the last line — where the URL handed
    /// back is literally ``validatedWatchURL(_:)``'s own output.
    func verified(_ candidate: URL, against request: Request) async -> ResolvedVideo? {
        guard let validated = Self.validatedWatchURL(candidate),
              let videoID = Self.watchVideoID(in: validated),
              let url = Self.oEmbedURL(for: validated),
              let response = await send(URLRequest(url: url)),
              response.statusCode == Self.verifiedStatusCode,
              let payload = try? JSONDecoder().decode(OEmbedPayload.self, from: response.body),
              payload.title.isEmpty == false,
              TitleMatch.matches(canonicalTitle: payload.title, request: request)
        else { return nil }
        return ResolvedVideo(videoId: videoID, url: validated, canonicalTitle: payload.title)
    }

    /// `https://www.youtube.com/oembed?url=<percent-encoded watch URL>&format=json`.
    ///
    /// `percentEncodedQuery` with an unreserved-only encoding is load-bearing:
    /// interpolating the watch URL raw would let its own `?v=` and the trailing
    /// `&format=` bind to the OUTER query, and YouTube would be asked about a URL
    /// that stops at `/watch`.
    static func oEmbedURL(for watchURL: URL) -> URL? {
        guard let encoded = watchURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: unreservedCharacters) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = canonicalHost
        components.path = oEmbedPath
        components.percentEncodedQuery = "url=\(encoded)&format=json"
        return components.url
    }

    // MARK: - Transport

    /// One round-trip with every failure flattened to `nil`.
    ///
    /// The status is deliberately NOT inspected here — callers apply their own
    /// gate, because "any 2xx" is right for a search and "exactly 200" is right for
    /// verification.
    private func send(_ request: URLRequest) async -> HTTPResponse? {
        try? await transport.send(request)
    }

    /// A trimmed, non-empty key, or `nil`. A blank field must behave exactly like
    /// no key at all rather than sending `Bearer `.
    private func resolvedKey(_ provider: (@Sendable () async throws -> String)?) async -> String? {
        guard let provider, let resolved = try? await provider() else { return nil }
        let key = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

// MARK: - Title matching

/// Scores an untrusted canonical title against what was asked for.
///
/// Folding is case-, diacritic- and width-insensitive, and tokens are the maximal
/// alphanumeric runs — so punctuation, quotes and emoji are separators, and a CJK
/// title (which carries no spaces) survives as a single meaningful token.
private enum TitleMatch {
    /// Below this, a Latin token is noise ("a", "I"). Non-ASCII tokens are exempt:
    /// one CJK character can be a whole word.
    static let minimumTokenLength = 2

    private static let separators = CharacterSet.alphanumerics.inverted

    /// True when the title shares at least HALF of the request's significant
    /// tokens. A request with no significant tokens (emoji-only, say) can never be
    /// verified, so it is false rather than vacuously true.
    static func matches(canonicalTitle: String, request: YouTubeLinkResolver.Request) -> Bool {
        let requested = tokens(in: request.searchQuery)
        guard requested.isEmpty == false else { return false }
        let shared = requested.intersection(tokens(in: canonicalTitle)).count
        return shared * 2 >= requested.count
    }

    static func tokens(in text: String) -> Set<String> {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        return Set(folded.components(separatedBy: separators).filter(isSignificant))
    }

    private static func isSignificant(_ token: String) -> Bool {
        if token.count >= minimumTokenLength { return true }
        return token.unicodeScalars.contains { $0.isASCII == false }
    }
}

// MARK: - Wire types

/// The keyless search request body. Only the three fields this resolver needs.
private struct SearchQuery: Encodable {
    var query: String
    var maxResults: Int
    var includeDomains: [String]

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
        case includeDomains = "include_domains"
    }
}

/// The keyless search reply. `url` is optional so one malformed hit cannot discard
/// the rest of the page.
private struct SearchPayload: Decodable {
    struct Hit: Decodable {
        var url: String?
    }

    var results: [Hit]
}

/// The YouTube Data API v3 `search.list` reply, narrowed to the one field that
/// matters. Every other field is unmodelled and `JSONDecoder` ignores it.
private struct DataAPISearchPayload: Decodable {
    struct Item: Decodable {
        var id: DataAPIVideoIdentifier
    }

    var items: [Item]
}

/// The `id` envelope of a `search.list` item. A sibling rather than a third
/// nesting level, which SwiftLint's `nesting` rule caps at two.
private struct DataAPIVideoIdentifier: Decodable {
    var videoId: String?
}

/// The oEmbed reply. `title` is REQUIRED here: a 200 whose body cannot produce one
/// — including the plain-text "Forbidden" observed with a 200 — fails to decode,
/// which is exactly the unresolved outcome that case deserves.
private struct OEmbedPayload: Decodable {
    var title: String
}
