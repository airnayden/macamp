// YouTubeLinkResolver — a song title in, a VERIFIED `watch?v=` link or nothing out.
//
// ── ONE VALIDATOR, ONE GATE ────────────────────────────────────────────────────
//
// ``YouTubeLinkResolver/validatedWatchURL(_:)`` is the SINGLE sanctioned check for
// "is this a YouTube watch URL". This resolver runs every candidate through it
// before returning, the view layer runs it again before rendering, and it is the
// only writer-gate for a suggestion's video link. A second hand-rolled check
// somewhere else would drift from this one, and the drift would show up as a
// rendered link to a host nobody vetted — so there is exactly one, it is `public`,
// and it is `static` so no instance is needed to call it.
//
// ── VERIFICATION IS oEmbed, NEVER HTML ─────────────────────────────────────────
//
// A candidate is confirmed by asking YouTube's oEmbed JSON endpoint about it (see
// `YouTubeLinkResolver+Search.swift`). Fetching or parsing `youtube.com/watch`
// HTML would violate the Terms of Service and is never done here.
//
// ── WHAT "VERIFIED" DOES AND DOES NOT CLAIM ────────────────────────────────────
//
// A resolved link is a video that EXISTS, is embeddable, and whose title shares at
// least half of the request's significant tokens. It is NOT a claim of official-
// upload identity: a cover, a live take or a lyric video can legitimately pass.
// Callers must describe the result as a verified MATCHING video, never as "the
// official video".
//
// ── UNTRUSTED INPUT, ZERO LOGGING ──────────────────────────────────────────────
//
// The oEmbed `title` is attacker-controlled text. It feeds exactly two places: the
// token-overlap check and ``ResolvedVideo/canonicalTitle``. It is never
// interpolated into a request, a format string, or a prompt. Nothing in either
// file logs a title, a query, or a key — a resolver that logged its inputs would
// leak the listener's library into the system log.
//
// ── KEYED BRANCH IS TEST-COVERED ONLY ──────────────────────────────────────────
//
// The YouTube Data API branch runs iff a key is injected. It ships covered by
// SCRIPTED-TRANSPORT TESTS ONLY — this repository holds no live key and makes no
// live request from a test. Keys arrive through the injected closures; this type
// never reads the Keychain itself.
import Foundation

/// Resolves "title + artist" into a verified YouTube watch link, or into `nil`.
///
/// Stateless and `Sendable`: it owns a transport and two credential closures, so a
/// settings change is expressed by building a new resolver rather than mutating a
/// live one.
public struct YouTubeLinkResolver: Sendable {
    /// What to look for. `artist` is optional because a suggestion may only carry
    /// a title, and the matcher degrades gracefully when it does.
    public struct Request: Sendable, Equatable {
        public var title: String
        public var artist: String?

        public init(title: String, artist: String? = nil) {
            self.title = title
            self.artist = artist
        }

        /// What both search branches send, and what the match check is scored
        /// against — artist first, mirroring how people name a song.
        var searchQuery: String {
            [artist ?? "", title]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        }
    }

    /// A link that passed the gate AND the oEmbed check.
    public struct ResolvedVideo: Sendable, Equatable {
        public let videoId: String
        /// Always the output of ``validatedWatchURL(_:)`` — canonical, credential-
        /// free, and stripped of every parameter except `v`.
        public let url: URL
        /// The title oEmbed reported. UNTRUSTED text; render it, never execute it.
        public let canonicalTitle: String

        public init(videoId: String, url: URL, canonicalTitle: String) {
            self.videoId = videoId
            self.url = url
            self.canonicalTitle = canonicalTitle
        }
    }

    /// How many lookups may be in flight at once.
    ///
    /// Each lookup is up to two round-trips and every one of them is a request the
    /// listener did not explicitly make, so the fan-out stays small: enough to keep
    /// a ten-song batch responsive, low enough that keyless search is not hammered.
    public static let maximumConcurrentLookups = 4

    /// The budget for a WHOLE batch, however many songs it holds.
    public static let defaultBatchDeadlineSeconds: TimeInterval = 30

    /// The only hosts a watch URL may carry. Compared against the lowercased host
    /// COMPONENT, never with `contains` — `youtube.com.evil.invalid` must fail.
    static let watchHosts: Set<String> = ["youtube.com", "www.youtube.com"]

    static let videoIDLength = 11

    // `internal` rather than `private`: `YouTubeLinkResolver+Search.swift` is a
    // separate FILE (SwiftLint's 400-line `file_length` ceiling forbids folding it
    // in here) and a `private` member is invisible across a file boundary. Nothing
    // outside this target can reach these, and no behaviour changes.
    static let canonicalHost = "www.youtube.com"
    static let watchPath = "/watch"

    private static let videoIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    let transport: any HTTPTransport
    let youTubeAPIKey: (@Sendable () async throws -> String)?
    let searchAPIKey: (@Sendable () async throws -> String)?
    private let batchDeadlineSeconds: TimeInterval

    /// - Parameters:
    ///   - transport: The one seam through which this type reaches the network.
    ///   - youTubeAPIKey: An OPTIONAL YouTube Data API key, resolved at call time.
    ///     Present ⇒ the keyed search branch; absent ⇒ the keyless one.
    ///   - searchAPIKey: An OPTIONAL keyless-search provider key. Present ⇒ a
    ///     bearer instead of the keyless access-mode header.
    ///   - batchDeadlineSeconds: The whole-batch budget.
    public init(
        transport: any HTTPTransport,
        youTubeAPIKey: (@Sendable () async throws -> String)? = nil,
        searchAPIKey: (@Sendable () async throws -> String)? = nil,
        batchDeadlineSeconds: TimeInterval = YouTubeLinkResolver.defaultBatchDeadlineSeconds
    ) {
        self.transport = transport
        self.youTubeAPIKey = youTubeAPIKey
        self.searchAPIKey = searchAPIKey
        self.batchDeadlineSeconds = batchDeadlineSeconds
    }

    // MARK: - The one validator

    /// The single sanctioned "is this a YouTube watch URL" check.
    ///
    /// Accepts only `https`, a host of exactly `youtube.com` or `www.youtube.com`,
    /// a path of exactly `/watch`, and a `v` of exactly 11 `[A-Za-z0-9_-]`
    /// characters. Anything else — a lookalike host, embedded credentials, a port,
    /// `youtu.be`, `/embed/`, a 10- or 12-character id — is `nil`.
    ///
    /// The return value is NORMALIZED, not the input: `https://www.youtube.com/watch?v=<id>`
    /// and nothing else, so tracking parameters, playlists and fragments cannot
    /// ride along. Callers should use what comes back, and the function is
    /// idempotent over its own output.
    public static func validatedWatchURL(_ url: URL) -> URL? {
        guard let videoID = watchVideoID(in: url) else { return nil }
        return watchURL(forVideoID: videoID)
    }

    /// The id carried by a strictly-conforming watch URL.
    static func watchVideoID(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host?.lowercased(), watchHosts.contains(host) else { return nil }
        // Credentials or a port mean the bytes before `/watch` are not really
        // YouTube, whatever the host component happens to say.
        guard components.user == nil, components.password == nil, components.port == nil else { return nil }
        guard components.path == watchPath else { return nil }
        guard let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        return isValidVideoID(videoID) ? videoID : nil
    }

    static func isValidVideoID(_ videoID: String) -> Bool {
        guard videoID.count == videoIDLength else { return false }
        return videoID.unicodeScalars.allSatisfy(videoIDCharacters.contains)
    }

    static func watchURL(forVideoID videoID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = canonicalHost
        components.path = watchPath
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    /// The first candidate that PASSES the gate. Both search branches return
    /// through here, so neither can invent its own notion of a valid link.
    static func firstValidWatchURL(in candidates: [URL]) -> URL? {
        candidates.compactMap(validatedWatchURL).first
    }

    // MARK: - Resolving

    /// Resolves one song. Never throws: an unresolved song is `nil`.
    public func resolve(_ request: Request) async -> ResolvedVideo? {
        await resolve([request]).first ?? nil
    }

    /// Resolves a batch, answering one slot per request IN ORDER.
    ///
    /// The whole batch shares a deadline. Blowing it yields an all-`nil` array
    /// rather than a partially-filled one, so a caller can never mistake "we ran
    /// out of time" for "that song has no video".
    public func resolve(_ requests: [Request]) async -> [ResolvedVideo?] {
        guard requests.isEmpty == false else { return [] }
        let resolved = try? await withDeadline(seconds: batchDeadlineSeconds) {
            await concurrentlyResolved(count: requests.count) { await resolveOne(requests[$0]) }
        }
        return resolved ?? Array(repeating: nil, count: requests.count)
    }

    /// Verifies video ids a CALLER proposed, one slot per request, IN ORDER.
    ///
    /// The search half is the caller's; the GATE is still entirely this type's —
    /// shape (``validatedWatchURL(_:)``), existence and embeddability (oEmbed),
    /// and "it is the song that was asked for" (the same token-overlap rule a
    /// searched candidate passes). A proposed id that fails any of them answers
    /// `nil`, exactly as a failed search does, so a caller can fall back.
    ///
    /// Exists because a model that just NAMED a song usually knows its canonical
    /// video id, and asking it costs nothing against the rate-capped search
    /// provider. An id it got wrong is caught here rather than rendered.
    ///
    /// - Parameter proposedIDs: One id per request, positionally. `nil` skips a
    ///   slot without spending a round-trip on it. A length mismatch answers
    ///   all-`nil` rather than pairing the wrong id to a song.
    public func verify(_ requests: [Request], proposedIDs: [String?]) async -> [ResolvedVideo?] {
        guard requests.isEmpty == false else { return [] }
        guard proposedIDs.count == requests.count else {
            return Array(repeating: nil, count: requests.count)
        }
        let verified = try? await withDeadline(seconds: batchDeadlineSeconds) {
            await concurrentlyResolved(count: requests.count) {
                await verifiedProposal(requests[$0], id: proposedIDs[$0])
            }
        }
        return verified ?? Array(repeating: nil, count: requests.count)
    }

    /// One slot per index, filled by at most ``maximumConcurrentLookups``
    /// lookups at a time: the first wave is launched up front, and each completion
    /// starts the next pending song.
    ///
    /// Generic over the per-slot operation so the searched path and the
    /// caller-proposed path share ONE fan-out and ONE ordering rule — two copies
    /// would eventually disagree about concurrency or about which slot a result
    /// belongs to.
    private func concurrentlyResolved(
        count: Int,
        _ operation: @escaping @Sendable (Int) async -> ResolvedVideo?
    ) async -> [ResolvedVideo?] {
        var results = [ResolvedVideo?](repeating: nil, count: count)
        await withTaskGroup(of: IndexedResolution.self) { group in
            var next = 0
            while next < min(Self.maximumConcurrentLookups, count) {
                let index = next
                group.addTask { await IndexedResolution(index: index, video: operation(index)) }
                next += 1
            }
            while let resolution = await group.next() {
                results[resolution.index] = resolution.video
                guard next < count else { continue }
                let index = next
                group.addTask { await IndexedResolution(index: index, video: operation(index)) }
                next += 1
            }
        }
        return results
    }

    private func resolveOne(_ request: Request) async -> ResolvedVideo? {
        guard let candidate = await searchForCandidate(request) else { return nil }
        return await verified(candidate, against: request)
    }

    /// One proposed id, through the same gate a searched candidate passes.
    private func verifiedProposal(_ request: Request, id: String?) async -> ResolvedVideo? {
        guard let id, let candidate = Self.watchURL(forVideoID: id) else { return nil }
        return await verified(candidate, against: request)
    }
}

/// One completed lookup, tagged with the slot it belongs to. A struct rather than
/// a tuple so the task group's element type stays readable.
private struct IndexedResolution {
    var index: Int
    var video: YouTubeLinkResolver.ResolvedVideo?
}
