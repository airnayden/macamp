// MusicBrainzInfoClient — the production ``OnlineInfoFetching`` over URLSession.
//
// Resolves narrative info in two hops, both rate-limited through ONE shared
// ``MusicBrainzRateLimiter`` (1 req/sec) so MusicBrainz + Wikipedia requests never
// collectively exceed the etiquette limit:
//   1. resolve the entity MBID — use the supplied MBID, else search MusicBrainz
//      by name (`/ws/2/{entity}?query=…&limit=1`);
//   2. look the entity up with `inc=url-rels+tags`, pull the `type == "wikipedia"`
//      URL relationship + the descriptive tags (+ first-release-date for albums);
//   3. parse the page title out of the Wikipedia URL and fetch the plain-text
//      summary from `…/api/rest_v1/page/summary/{title}` — its `extract` becomes
//      the biography / description.
//
// A 404 anywhere means "no info" (returns `nil`), never an error. The pure parse
// seams live in ``MusicBrainzInfoParsing.swift`` so `@testable` tests can lock the
// JSON mapping without a live network request.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import os.log

/// Errors surfaced by ``MusicBrainzInfoClient``.
public enum OnlineInfoError: Error, Equatable {
    case invalidURL
    case httpStatus(Int)
}

/// The production ``OnlineInfoFetching`` backed by `URLSession`, MusicBrainz, and
/// the Wikipedia REST summary API.
public struct MusicBrainzInfoClient: OnlineInfoFetching {
    let session: URLSession
    let mbBaseURLString: String
    let wikipediaBaseURLString: String
    let userAgent: String
    let limiter: MusicBrainzRateLimiter

    /// Creates a client. Inject the SAME `limiter` used by ``MusicBrainzClient`` so
    /// both share one 1-req/sec gate to musicbrainz.org; when `nil`, a private
    /// limiter is created from `minimumInterval`.
    public init(
        session: URLSession = .shared,
        mbBaseURLString: String = "https://musicbrainz.org",
        wikipediaBaseURLString: String = "https://en.wikipedia.org",
        userAgent: String = "MacAMP/1.0 (https://example.com)",
        minimumInterval: Duration = .seconds(1),
        limiter: MusicBrainzRateLimiter? = nil
    ) {
        self.session = session
        self.mbBaseURLString = mbBaseURLString
        self.wikipediaBaseURLString = wikipediaBaseURLString
        self.userAgent = userAgent
        self.limiter = limiter ?? MusicBrainzRateLimiter(minimumInterval: minimumInterval)
    }
}

// MARK: - Public fetch surface

public extension MusicBrainzInfoClient {
    func fetchArtistInfo(name: String, mbid: String?) async throws -> ArtistInfo? {
        guard let detail = try await resolveDetail(kind: .artist, name: name, secondary: nil, mbid: mbid) else {
            return nil
        }
        let summary = try await wikipediaSummary(forURLString: detail.wikipediaURLString)
        let info = ArtistInfo(biography: summary.extract, tags: detail.tagNames, imageURL: summary.imageURL)
        return info.isEmpty ? nil : info
    }

    func fetchAlbumInfo(title: String, artist: String?, mbid: String?) async throws -> AlbumInfo? {
        guard let detail = try await resolveDetail(
            kind: .releaseGroup, name: title, secondary: artist, mbid: mbid
        ) else { return nil }
        let summary = try await wikipediaSummary(forURLString: detail.wikipediaURLString)
        let info = AlbumInfo(
            description: summary.extract, tags: detail.tagNames, releaseDate: detail.firstReleaseDate
        )
        return info.isEmpty ? nil : info
    }

    func fetchTrackInfo(title: String, artist: String?, mbid: String?) async throws -> TrackInfo? {
        guard let detail = try await resolveDetail(
            kind: .recording, name: title, secondary: artist, mbid: mbid
        ) else { return nil }
        let summary = try await wikipediaSummary(forURLString: detail.wikipediaURLString)
        let info = TrackInfo(description: summary.extract, tags: detail.tagNames)
        return info.isEmpty ? nil : info
    }
}

// MARK: - Network orchestration

private extension MusicBrainzInfoClient {
    /// Resolves the entity MBID (given or searched) then looks it up with
    /// `inc=url-rels+tags`, returning the parsed relations/tags/date.
    func resolveDetail(
        kind: MBInfoEntityKind,
        name: String,
        secondary: String?,
        mbid: String?
    ) async throws -> MBInfoParsedDetail? {
        guard let id = try await resolveMBID(kind: kind, name: name, secondary: secondary, mbid: mbid) else {
            print("[InfoClient] ✗ no MBID found for \(kind.searchField)=\(name)")
            return nil
        }
        print("[InfoClient] ✓ resolved MBID \(id) for \(name)")
        guard let request = try lookupRequest(kind: kind, mbid: id),
              let data = try await fetch(request)
        else { return nil }
        let detail = Self.parseEntityDetail(from: data)
        if let wikipediaURLString = detail.wikipediaURLString {
            print("[InfoClient] ✓ Wikipedia: \(wikipediaURLString)")
        } else {
            print("[InfoClient] ✗ no Wikipedia link for \(name) (MBID \(id))")
        }
        return detail
    }

    func resolveMBID(
        kind: MBInfoEntityKind,
        name: String,
        secondary: String?,
        mbid: String?
    ) async throws -> String? {
        if let mbid = Self.nonBlank(mbid) { return mbid }
        guard let request = try searchRequest(kind: kind, name: name, secondary: secondary),
              let data = try await fetch(request)
        else { return nil }
        let id = Self.firstSearchID(from: data, kind: kind)
        if id == nil {
            print("[InfoClient] ✗ MB search returned no results for \(kind.searchField)=\(name)")
        }
        return id
    }

    func wikipediaSummary(forURLString urlString: String?) async throws -> WikipediaSummary {
        guard let urlString,
              var title = Self.wikipediaTitle(fromURLString: urlString)
        else { return WikipediaSummary() }

        if title.hasPrefix("wikidata:") {
            let qid = String(title.dropFirst("wikidata:".count))
            guard let resolved = try await resolveWikidataToWikipedia(qid: qid) else {
                print("[InfoClient] ✗ Wikidata \(qid) has no enwiki sitelink")
                return WikipediaSummary()
            }
            title = resolved
            print("[InfoClient] ✓ Wikidata \(qid) → Wikipedia \"\(title)\"")
        }

        guard let request = try wikipediaRequest(title: title),
              let data = try await fetch(request)
        else { return WikipediaSummary() }
        return Self.parseWikipediaSummary(from: data)
    }

    func resolveWikidataToWikipedia(qid: String) async throws -> String? {
        guard let url = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json") else {
            return nil
        }
        let request = Self.makeGET(url, userAgent: userAgent)
        guard let data = try await fetch(request) else { return nil }
        return Self.parseWikidataEnwikiTitle(from: data, qid: qid)
    }

    /// Awaits the shared rate-limit slot, performs the request, and maps the
    /// status: 404 → `nil` (no info), non-200 → throw, 200 → the body data.
    static let log = Logger(subsystem: "si.macamp.MacAMP", category: "InfoClient")

    func fetch(_ request: URLRequest) async throws -> Data? {
        let url = request.url?.absoluteString ?? "?"
        Self.log.notice("[InfoClient] → GET \(url, privacy: .public)")
        print("[InfoClient] → GET \(url)")
        await limiter.awaitSlot()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Self.log.error("[InfoClient] ← no HTTP response for \(url, privacy: .public)")
                print("[InfoClient] ← no HTTP response for \(url)")
                throw OnlineInfoError.httpStatus(-1)
            }
            Self.log.notice("[InfoClient] ← \(http.statusCode) \(url, privacy: .public) (\(data.count) bytes)")
            print("[InfoClient] ← \(http.statusCode) \(url) (\(data.count) bytes)")
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else {
                throw OnlineInfoError.httpStatus(http.statusCode)
            }
            return data
        } catch let error as OnlineInfoError {
            throw error
        } catch {
            Self.log.error("[InfoClient] ← network error: \(error.localizedDescription, privacy: .public)")
            print("[InfoClient] ← network error: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Request construction

private extension MusicBrainzInfoClient {
    func searchRequest(kind: MBInfoEntityKind, name: String, secondary: String?) throws -> URLRequest? {
        let query = Self.searchQuery(kind: kind, name: name, secondary: secondary)
        guard !query.isEmpty else { return nil }
        guard var components = URLComponents(string: mbBaseURLString) else {
            throw OnlineInfoError.invalidURL
        }
        components.path = kind.path
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { throw OnlineInfoError.invalidURL }
        return Self.makeGET(url, userAgent: userAgent)
    }

    func lookupRequest(kind: MBInfoEntityKind, mbid: String) throws -> URLRequest? {
        let id = mbid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard var components = URLComponents(string: mbBaseURLString) else {
            throw OnlineInfoError.invalidURL
        }
        components.path = "\(kind.path)/\(id)"
        components.queryItems = [
            URLQueryItem(name: "inc", value: "url-rels+tags"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { throw OnlineInfoError.invalidURL }
        return Self.makeGET(url, userAgent: userAgent)
    }

    func wikipediaRequest(title: String) throws -> URLRequest? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.titleAllowed)
        else { return nil }
        guard let url = URL(string: "\(wikipediaBaseURLString)/api/rest_v1/page/summary/\(encoded)") else {
            throw OnlineInfoError.invalidURL
        }
        return Self.makeGET(url, userAgent: userAgent)
    }
}

// MARK: - Entity kinds

/// The three MusicBrainz entities MacAMP resolves info for, with their web-service
/// path and Lucene search field.
enum MBInfoEntityKind {
    case artist
    case releaseGroup
    case recording

    /// The `/ws/2/…` base path for both search and (with `/{mbid}`) lookup.
    var path: String {
        switch self {
        case .artist: "/ws/2/artist"
        case .releaseGroup: "/ws/2/release-group"
        case .recording: "/ws/2/recording"
        }
    }

    /// The Lucene field the entity is searched by.
    var searchField: String {
        switch self {
        case .artist: "artist"
        case .releaseGroup: "releasegroup"
        case .recording: "recording"
        }
    }
}
