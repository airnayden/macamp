import Foundation
import os

// LRCLIBClient — the production LRCLIB fetch implementation over URLSession.
//
// LRCLIB (https://lrclib.net/docs) is a free, no-key lyrics API. We hit
// `GET /api/get?artist_name=&track_name=&album_name=&duration=` and map the JSON
// body to ``OnlineLyricsResult``.
//
// `/api/get` is a *signature* match — LRCLIB answers only when the supplied
// artist/title/album/duration all line up (duration within ~2 s), so a track whose
// tags differ slightly from the database 404s even when the lyrics exist. On that
// 404 we fall back to `GET /api/search`, a keyword search, and keep the candidate
// whose duration is closest to ours (``durationTolerance``). A 404 that survives
// the fallback means "no match" (returns `nil`), not an error.
//
// IMPORTANT: this type is NEVER instantiated in a test path — tests inject
// ``MockLRCLIBFetcher`` so no live network request is made. Fetching is also
// strictly opt-in at the ``LyricsService`` layer (``LyricsOptions/allowOnlineFetch``).
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// Errors surfaced by ``LRCLIBClient``.
public enum OnlineLyricsError: Error, Equatable {
    /// The configured base URL or query could not form a valid request URL.
    case invalidURL
    /// Online service returned a non-200, non-404 HTTP status.
    case httpStatus(Int)
}

/// One `/api/search` result row — a *candidate* recording, not a confirmed match.
///
/// `/api/search` ranks by keyword relevance, so the caller still has to decide
/// which row is the same recording; ``LRCLIBClient/bestCandidate(from:duration:)``
/// does that by duration proximity.
public struct LRCLIBSearchCandidate: Decodable, Sendable, Equatable {
    /// LRCLIB's own row id.
    public let id: Int?
    /// The track title LRCLIB has on file.
    public let trackName: String?
    /// The artist name LRCLIB has on file.
    public let artistName: String?
    /// The album title LRCLIB has on file.
    public let albumName: String?
    /// Recording length in seconds — the field the match is decided on.
    public let duration: TimeInterval?
    /// `true` when LRCLIB flags the recording as instrumental.
    public let instrumental: Bool?
    /// Plain (unsynced) lyrics, if this candidate carries any.
    public let plainLyrics: String?
    /// Synced lyrics in `.lrc` form, if this candidate carries any.
    public let syncedLyrics: String?

    public init(
        id: Int? = nil,
        trackName: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        duration: TimeInterval? = nil,
        instrumental: Bool? = nil,
        plainLyrics: String? = nil,
        syncedLyrics: String? = nil
    ) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }
}

/// The production ``OnlineLyricsFetching`` backed by `URLSession`.
public struct LRCLIBClient: OnlineLyricsFetching {
    /// The widest gap (seconds) between a candidate's duration and the requested
    /// one that still counts as the same recording. Anything further apart is a
    /// different edit (radio cut, live take, extended mix) and is rejected.
    public static let durationTolerance: TimeInterval = 15

    static let log = Logger(subsystem: "si.macamp.MacAMP", category: "lyrics-online")

    private let session: URLSession
    private let baseURLString: String
    private let userAgent: String

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - session: The `URLSession` to use (defaults to `.shared`).
    ///   - baseURLString: The LRCLIB origin (defaults to `https://lrclib.net`).
    ///   - userAgent: A descriptive User-Agent (LRCLIB etiquette).
    public init(
        session: URLSession = .shared,
        baseURLString: String = "https://lrclib.net",
        userAgent: String = "MacAMP (+https://github.com/macamp)"
    ) {
        self.session = session
        self.baseURLString = baseURLString
        self.userAgent = userAgent
    }

    public func fetch(
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> OnlineLyricsResult? {
        let request = try makeRequest(artist: artist, title: title, album: album, duration: duration)
        Self.log.debug("get → \(Self.describe(artist: artist, title: title), privacy: .public)")
        guard let data = try await perform(request, label: "get") else {
            Self.log.debug("get 404 — falling back to search")
            return try await searchFallback(artist: artist, title: title, duration: duration)
        }
        let decoded = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
        Self.log.debug("get hit")
        return OnlineLyricsResult(
            plainLyrics: decoded.plainLyrics,
            syncedLyrics: decoded.syncedLyrics,
            isInstrumental: decoded.instrumental ?? false
        )
    }

    /// Keyword-searches LRCLIB for candidate recordings.
    ///
    /// `/api/search` requires `q` or `track_name`, so `title` is non-optional here
    /// — a caller with no usable title must not search at all. A 404 is treated as
    /// an empty candidate list; any other non-200 throws.
    public func search(artist: String?, title: String) async throws -> [LRCLIBSearchCandidate] {
        let request = try makeSearchRequest(artist: artist, title: title)
        Self.log.debug("search → \(Self.describe(artist: artist, title: title), privacy: .public)")
        guard let data = try await perform(request, label: "search") else { return [] }
        return try JSONDecoder().decode([LRCLIBSearchCandidate].self, from: data)
    }
}

// MARK: - Fallback + candidate selection

private extension LRCLIBClient {
    /// The `/api/get` 404 fallback.
    ///
    /// Skipped entirely without a usable title: LRCLIB's `/api/search` requires
    /// `q` or `track_name`, so a title-less request would 400 and surface as a
    /// false "service failure" — with nothing to search on, no-match is the honest
    /// answer.
    func searchFallback(
        artist: String?,
        title: String?,
        duration: TimeInterval?
    ) async throws -> OnlineLyricsResult? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            Self.log.debug("search skipped — no usable title")
            return nil
        }
        let candidates = try await search(artist: artist, title: trimmed)
        guard let best = Self.bestCandidate(from: candidates, duration: duration) else {
            Self.log.debug("search miss — \(candidates.count, privacy: .public) candidate(s), none within tolerance")
            return nil
        }
        Self.log.debug("search hit — candidate \(best.id ?? -1, privacy: .public)")
        return OnlineLyricsResult(
            plainLyrics: best.plainLyrics,
            syncedLyrics: best.syncedLyrics,
            isInstrumental: best.instrumental ?? false
        )
    }
}

extension LRCLIBClient {
    /// Picks the candidate most likely to *be* the requested recording.
    ///
    /// With a known `duration`: the candidate minimizing
    /// `abs(candidate.duration - duration)`, rejecting the whole set when even the
    /// closest is further than ``durationTolerance`` away; ties prefer a candidate
    /// carrying synced lyrics. A candidate with no duration cannot be gated, so it
    /// is dropped.
    ///
    /// With no `duration` there is nothing to gate on, so the first candidate
    /// carrying synced lyrics wins, else simply the first candidate.
    static func bestCandidate(
        from candidates: [LRCLIBSearchCandidate],
        duration: TimeInterval?
    ) -> LRCLIBSearchCandidate? {
        guard let duration else {
            return candidates.first { $0.syncedLyrics != nil } ?? candidates.first
        }
        return candidates
            .compactMap { candidate -> (candidate: LRCLIBSearchCandidate, delta: TimeInterval)? in
                guard let length = candidate.duration else { return nil }
                let delta = abs(length - duration)
                return delta <= durationTolerance ? (candidate, delta) : nil
            }
            .min { lhs, rhs in
                if lhs.delta != rhs.delta { return lhs.delta < rhs.delta }
                return lhs.candidate.syncedLyrics != nil && rhs.candidate.syncedLyrics == nil
            }?
            .candidate
    }

    /// A compact one-liner naming the pair a request is keyed on.
    static func describe(artist: String?, title: String?) -> String {
        "artist=\(artist ?? "-") title=\(title ?? "-")"
    }
}

// MARK: - Transport

private extension LRCLIBClient {
    /// Runs `request` and maps the status: 404 → `nil` (no match), any other
    /// non-200 → a thrown ``OnlineLyricsError/httpStatus(_:)``, 200 → the body.
    ///
    /// Transport errors propagate untouched, so a genuine network failure is never
    /// mistaken for "this track has no lyrics".
    func perform(_ request: URLRequest, label: String) async throws -> Data? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Self.log.error("\(label, privacy: .public) ← no HTTP response")
                throw OnlineLyricsError.httpStatus(-1)
            }
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else {
                Self.log.error("\(label, privacy: .public) ← HTTP \(http.statusCode, privacy: .public)")
                throw OnlineLyricsError.httpStatus(http.statusCode)
            }
            return data
        } catch let error as OnlineLyricsError {
            throw error
        } catch {
            Self.log.error(
                "\(label, privacy: .public) ← network error: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}

// MARK: - Request construction

private extension LRCLIBClient {
    func makeRequest(
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURLString) else {
            throw OnlineLyricsError.invalidURL
        }
        components.path = "/api/get"
        var items: [URLQueryItem] = []
        if let artist { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let title { items.append(URLQueryItem(name: "track_name", value: title)) }
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            throw OnlineLyricsError.invalidURL
        }
        return makeGET(url)
    }

    /// Builds the `/api/search` request.
    ///
    /// Deliberately narrower than ``makeRequest(artist:title:album:duration:)``:
    /// `album_name` is left off because the fallback runs precisely when the exact
    /// signature already failed, and one more constraint would only narrow it further.
    func makeSearchRequest(artist: String?, title: String) throws -> URLRequest {
        guard var components = URLComponents(string: baseURLString) else {
            throw OnlineLyricsError.invalidURL
        }
        components.path = "/api/search"
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        components.queryItems = items
        guard let url = components.url else {
            throw OnlineLyricsError.invalidURL
        }
        return makeGET(url)
    }

    /// A GET carrying the LRCLIB-etiquette User-Agent — the one place the header is
    /// set, so `/api/get` and `/api/search` can never drift apart.
    func makeGET(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// The subset of the LRCLIB `/api/get` JSON body MacAMP consumes.
private struct LRCLIBResponse: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let instrumental: Bool?
}
