// MusicBrainzClient — the production online metadata lookup over URLSession.
//
// Queries the MusicBrainz web service (https://musicbrainz.org/doc/MusicBrainz_API):
// `GET /ws/2/recording?query=artist:"…"+recording:"…"&fmt=json&limit=1` and maps
// the first match to ``MetadataLookupResult``. No API key is required.
//
// MusicBrainz REQUIRES a descriptive User-Agent and rate-limits anonymous callers
// to ~1 request/second. This client always sends a User-Agent and serialises its
// requests so consecutive lookups are spaced at least ``minimumInterval`` apart
// (an internal ``RateLimiter`` actor). A 404 means "no match" (returns `nil`), not
// an error.
//
// IMPORTANT: this type is NEVER instantiated on a test/preview path — those inject
// ``MockMetadataFetcher`` so no live network request is made.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation

/// Errors surfaced by ``MusicBrainzClient``.
public enum OnlineMetadataError: Error, Equatable {
    /// The configured base URL or query could not form a valid request URL.
    case invalidURL
    /// MusicBrainz returned a non-200, non-404 HTTP status.
    case httpStatus(Int)
}

/// The production ``OnlineMetadataFetching`` backed by `URLSession` + MusicBrainz.
public struct MusicBrainzClient: OnlineMetadataFetching {
    private let session: URLSession
    private let baseURLString: String
    private let userAgent: String
    private let limiter: MusicBrainzRateLimiter

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - session: the `URLSession` to use (defaults to `.shared`).
    ///   - baseURLString: the MusicBrainz origin (defaults to the public server).
    ///   - userAgent: a descriptive User-Agent (MusicBrainz REQUIRES one).
    ///   - minimumInterval: minimum spacing between requests when no shared
    ///     `limiter` is injected (defaults to one second).
    ///   - limiter: an optional SHARED ``MusicBrainzRateLimiter``. Inject the same
    ///     instance here and into ``MusicBrainzInfoClient`` so both clients share a
    ///     single 1-req/sec gate to musicbrainz.org. When `nil`, a private limiter
    ///     is created from `minimumInterval`.
    public init(
        session: URLSession = .shared,
        baseURLString: String = "https://musicbrainz.org",
        userAgent: String = "MacAMP/1.0 (https://example.com)",
        minimumInterval: Duration = .seconds(1),
        limiter: MusicBrainzRateLimiter? = nil
    ) {
        self.session = session
        self.baseURLString = baseURLString
        self.userAgent = userAgent
        self.limiter = limiter ?? MusicBrainzRateLimiter(minimumInterval: minimumInterval)
    }

    public func lookup(
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> MetadataLookupResult? {
        guard let request = try makeRequest(artist: artist, title: title, album: album) else {
            return nil
        }
        await limiter.awaitSlot()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OnlineMetadataError.httpStatus(-1)
        }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw OnlineMetadataError.httpStatus(http.statusCode)
        }
        return try Self.parseFirstMatch(from: data, duration: duration)
    }

    /// Builds the search request, or `nil` when there is nothing usable to search
    /// for (no artist AND no title) — so the caller short-circuits without a request.
    private func makeRequest(artist: String?, title: String?, album: String?) throws -> URLRequest? {
        let query = Self.luceneQuery(artist: artist, title: title, album: album)
        guard !query.isEmpty else { return nil }
        guard var components = URLComponents(string: baseURLString) else {
            throw OnlineMetadataError.invalidURL
        }
        components.path = "/ws/2/recording"
        // Five candidates, not one: MusicBrainz ranks on text relevance alone, so the top
        // hit is routinely a different edit of the same song. Still ONE request.
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else {
            throw OnlineMetadataError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func lookupComposer(recordingID: String) async throws -> String? {
        guard let request = try makeComposerRequest(recordingID: recordingID) else {
            return nil
        }
        await limiter.awaitSlot()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OnlineMetadataError.httpStatus(-1)
        }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw OnlineMetadataError.httpStatus(http.statusCode)
        }
        return Self.parseComposer(from: data)
    }

    /// Builds the recording-lookup request whose `inc` pulls the linked work plus
    /// the work's own artist relationships in ONE call, or `nil` for a blank MBID.
    private func makeComposerRequest(recordingID: String) throws -> URLRequest? {
        let mbid = recordingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mbid.isEmpty else { return nil }
        guard var components = URLComponents(string: baseURLString) else {
            throw OnlineMetadataError.invalidURL
        }
        components.path = "/ws/2/recording/\(mbid)"
        components.queryItems = [
            URLQueryItem(name: "inc", value: "work-rels+work-level-rels+artist-rels"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else {
            throw OnlineMetadataError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

// MARK: - Query construction (internal test seam)

extension MusicBrainzClient {
    /// Composes the Lucene `query` value: `artist:"…" AND recording:"…" AND release:"…"`,
    /// phrase-quoting each present term and dropping the blank ones. Exposed
    /// `internal` so a `@testable` test can lock the query format; production calls
    /// it via ``makeRequest``.
    static func luceneQuery(artist: String?, title: String?, album: String?) -> String {
        var clauses: [String] = []
        if let artist = nonBlank(artist) { clauses.append("artist:\(quote(artist))") }
        if let title = nonBlank(title) { clauses.append("recording:\(quote(title))") }
        if let album = nonBlank(album) { clauses.append("release:\(quote(album))") }
        return clauses.joined(separator: " AND ")
    }

    private static func quote(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Response mapping (internal test seam)

extension MusicBrainzClient {
    /// The widest gap (seconds) between a candidate's length and the requested
    /// duration that still counts as the same recording — anything further apart is a
    /// different edit (radio cut, live take, extended mix). Mirrors the lyrics client.
    static let durationTolerance: TimeInterval = 15

    /// Picks the candidate most likely to *be* the requested recording.
    ///
    /// With a known `duration` the winner minimizes `abs(length − duration)` among the
    /// candidates within ``durationTolerance``; equal deltas keep MusicBrainz's own
    /// ranking. When nothing qualifies — no `duration`, no candidate carries a
    /// `length`, or every one is out of tolerance — the first candidate wins.
    static func bestMatch(from recordings: [MBRecording], duration: TimeInterval?) -> MBRecording? {
        guard let duration else { return recordings.first }
        let nearest = recordings
            .compactMap { candidate -> (recording: MBRecording, delta: TimeInterval)? in
                guard let length = candidate.length else { return nil }
                let delta = abs(TimeInterval(length) / 1000 - duration)
                return delta <= durationTolerance ? (candidate, delta) : nil
            }
            .min { $0.delta < $1.delta }
        return nearest?.recording ?? recordings.first
    }

    /// Decodes a MusicBrainz `/ws/2/recording` search body and maps the best candidate
    /// — ``bestMatch(from:duration:)`` with a `duration`, else the first (search-ranked)
    /// recording — to a ``MetadataLookupResult``, or `nil` when the body has no
    /// recordings. Exposed `internal` for `@testable` tests; production calls it via
    /// ``lookup(artist:title:album:duration:)``.
    ///
    /// - Throws: a `DecodingError` for a malformed body (never for "no match").
    static func parseFirstMatch(from data: Data, duration: TimeInterval? = nil) throws -> MetadataLookupResult? {
        let response = try JSONDecoder().decode(MBSearchResponse.self, from: data)
        guard let recording = bestMatch(from: response.recordings ?? [], duration: duration) else { return nil }
        let release = recording.releases?.first
        let result = MetadataLookupResult(
            title: recording.title,
            artist: recording.creditedArtist,
            album: release?.title,
            albumArtist: nil,
            genre: recording.primaryGenre,
            year: release?.releaseYear,
            trackNumber: release?.firstTrackNumber,
            discNumber: release?.firstDiscNumber,
            artworkURL: release?.coverArtURL,
            recordingID: recording.id
        )
        return result.isEmpty ? nil : result
    }

    /// Parses a leading 4-digit Gregorian year from a MusicBrainz date string
    /// (`"1969"`, `"1969-09-26"`), or `nil` when absent/too short.
    static func year(from dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }

    /// Extracts the first "composer" artist credited to any work linked to the
    /// recording in a `/ws/2/recording/{mbid}?inc=work-rels+work-level-rels+artist-rels`
    /// body. A malformed/relation-free body is "no composer" (`nil`), never an
    /// error — composer enrichment is strictly best-effort. Exposed `internal` for
    /// `@testable` tests; production calls it via ``lookupComposer(recordingID:)``.
    static func parseComposer(from data: Data) -> String? {
        guard let detail = try? JSONDecoder().decode(MBRecordingDetail.self, from: data) else {
            return nil
        }
        return detail.composerName
    }
}

// MARK: - MusicBrainz JSON (the subset MacAMP consumes)

struct MBSearchResponse: Decodable {
    let recordings: [MBRecording]?
}

struct MBRecording: Decodable {
    let id: String?
    let title: String?
    let artistCredit: [MBArtistCredit]?
    let releases: [MBRelease]?
    let tags: [MBTag]?
    let genres: [MBTag]?
    /// Recording length in MILLISECONDS — the field duration matching is decided on.
    let length: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, releases, tags, genres
        case length
        case artistCredit = "artist-credit"
    }

    /// The full credited-artist string, joining each credit with its joinphrase
    /// (e.g. `"A feat. B"`), or `nil` when there is no credit.
    var creditedArtist: String? {
        guard let artistCredit, !artistCredit.isEmpty else { return nil }
        let joined = artistCredit
            .map { ($0.name ?? "") + ($0.joinphrase ?? "") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// The highest-weighted name from curated `genres`, falling back to folksonomy
    /// `tags`, title-cased; `nil` when neither is present.
    var primaryGenre: String? {
        let pool = (genres?.isEmpty == false ? genres : tags) ?? []
        let best = pool.max { ($0.count ?? 0) < ($1.count ?? 0) }
        guard let name = best?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name.capitalized(with: Locale(identifier: "en_US"))
    }
}

struct MBArtistCredit: Decodable {
    let name: String?
    let joinphrase: String?
}

struct MBRelease: Decodable {
    let id: String?
    let title: String?
    let date: String?
    let media: [MBMedium]?
    let releaseGroup: MBReleaseGroup?

    enum CodingKeys: String, CodingKey {
        case id, title, date, media
        case releaseGroup = "release-group"
    }

    /// Release year from the release `date`, falling back to the release group's
    /// first-release date.
    var releaseYear: Int? {
        MusicBrainzClient.year(from: date) ?? MusicBrainzClient.year(from: releaseGroup?.firstReleaseDate)
    }

    /// The first medium's first track number (`"number"` parsed, else `position`).
    var firstTrackNumber: Int? {
        guard let track = media?.first?.track?.first else { return nil }
        if let number = track.number, let parsed = Int(number) { return parsed }
        return track.position
    }

    /// The first medium's 1-based position (its disc number).
    var firstDiscNumber: Int? {
        media?.first?.position
    }

    /// The Cover Art Archive front-image URL for this release MBID, if any.
    var coverArtURL: URL? {
        guard let id, !id.isEmpty else { return nil }
        return URL(string: "https://coverartarchive.org/release/\(id)/front")
    }
}

struct MBReleaseGroup: Decodable {
    let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case firstReleaseDate = "first-release-date"
    }
}

struct MBMedium: Decodable {
    let position: Int?
    let track: [MBTrackEntry]?
}

struct MBTrackEntry: Decodable {
    let number: String?
    let position: Int?
}

struct MBTag: Decodable {
    let count: Int?
    let name: String?
}

// MARK: - MusicBrainz work-relationship JSON (composer lookup)

private struct MBRecordingDetail: Decodable {
    let relations: [MBRelation]?

    var composerName: String? {
        relations?
            .lazy
            .filter { $0.targetType == "work" }
            .compactMap { $0.work?.composerName }
            .first
    }
}

private struct MBRelation: Decodable {
    let type: String?
    let targetType: String?
    let artist: MBRelationArtist?
    let work: MBWork?

    enum CodingKeys: String, CodingKey {
        case type, artist, work
        case targetType = "target-type"
    }
}

private struct MBWork: Decodable {
    let relations: [MBRelation]?

    var composerName: String? {
        relations?
            .lazy
            .filter { $0.type == "composer" && $0.targetType == "artist" }
            .compactMap { $0.artist?.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct MBRelationArtist: Decodable {
    let name: String?
}
