// YouTubeOEmbed — the keyless paste-time metadata lookup, POLICY half.
//
// The downloader learns a video's title, uploader and thumbnail URL from YouTube's
// public oEmbed endpoint. No API key exists for it, none is used, and the
// `youtube.com/watch` HTML is never fetched or parsed — that would violate the
// Terms of Service. One JSON document, one optional image fetch, nothing else.
//
// ── WHY THIS FILE HOLDS NO TRANSPORT ─────────────────────────────────────────
//
// `scripts/check-downloader-boundary.sh` permits `URLSession` in exactly two files,
// neither of them this one, so everything here is pure: the request URL, the wire
// shape, the "what counts as an answer" decision, the concurrency window and the
// timeout policy. The bytes are moved by
// `macOS/Sources/Downloads/YouTubeOEmbedClient.swift`, the second sanctioned
// transport — including the THUMBNAIL bytes, which deliberately do not get a
// transport of their own.
//
// The split is `DownloadToolProviding` / `DownloadToolReleaseClient`'s, applied
// again: the interesting half (URL construction, status policy, decoding, the
// window) is driven by tests with zero I/O, and the shell file is a shim.
//
// ── ONLY A 2xx WITH A DECODABLE, NON-EMPTY TITLE IS AN ANSWER ────────────────
//
// The status taxonomy for a missing or private video is not stable enough to
// branch on — 400, 401 and 404 have all been observed for the same class of
// failure, and a plain-text "Forbidden" body has been seen carrying a 200. So the
// only accepting branch is "2xx whose body decodes into a non-empty title", and
// every other outcome — a 404, a 401, a timeout, a truncated or non-JSON body —
// collapses to the same silent `nil`. This is decoration: a caller shows what it
// has and never tells the listener a lookup failed.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

// MARK: - Wire shape

/// The three fields MacAMP reads out of an oEmbed answer.
///
/// `duration` is deliberately absent: it is not part of the oEmbed specification
/// and YouTube does not publish it here. Duration keeps coming from the
/// dequeue-time `-J` metadata pass, which stays authoritative for every field.
public struct OEmbedPayload: Sendable, Equatable, Hashable, Decodable {
    /// The video title. REQUIRED and non-empty — an answer that cannot produce one
    /// tells the caller nothing, so it is treated as no answer at all.
    ///
    /// UNTRUSTED text: render it, never interpolate it into a request or a prompt.
    public let title: String
    /// The channel name, when the answer carried one.
    public let authorName: String?
    /// Where the poster frame lives, when the answer carried one. Fetching it is a
    /// separate, optional round-trip through ``OEmbedFetching/fetchThumbnail(url:)``.
    public let thumbnailURL: URL?

    public init(title: String, authorName: String? = nil, thumbnailURL: URL? = nil) {
        self.title = title
        self.authorName = authorName
        self.thumbnailURL = thumbnailURL
    }

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case thumbnailURL = "thumbnail_url"
    }

    /// Hand-written so a malformed `thumbnail_url` degrades to `nil` instead of
    /// discarding an otherwise-good title: `URL`'s synthesised `Decodable` throws
    /// on a string it cannot parse, which would fail the whole payload over a
    /// field nothing depends on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        thumbnailURL = try container
            .decodeIfPresent(String.self, forKey: .thumbnailURL)
            .flatMap(URL.init(string:))
    }
}

/// One raw HTTP answer, as the transport half saw it.
///
/// The seam type: the shell reports status + body, and every judgement about them
/// is made here by ``YouTubeOEmbed``. A `nil` `OEmbedResponse` means the request
/// never completed at all — timeout, DNS failure, offline.
public struct OEmbedResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

// MARK: - The seam

/// Fetches decorative paste-time metadata for a queued download.
///
/// Nothing here throws and nothing here reports a failure: every method answers
/// `nil` when the lookup did not produce something worth showing. A caller must be
/// able to ignore this seam entirely and still work — enqueue is never blocked on
/// it, and `-J` overwrites whatever it produced at dequeue.
///
/// `Sendable`, not `@MainActor`: conformers are driven from detached tasks.
public protocol OEmbedFetching: Sendable {
    /// The title / uploader / thumbnail URL for `videoID`, or `nil`.
    func fetch(videoID: String) async -> OEmbedPayload?

    /// The raw bytes of a poster frame, or `nil`.
    ///
    /// Rides the SAME transport as ``fetch(videoID:)`` on purpose — a second egress
    /// path for images is exactly what the downloader boundary guard exists to
    /// prevent.
    func fetchThumbnail(url: URL) async -> Data?
}

// MARK: - Policy

/// Request construction, response judgement, and the two numeric policies.
///
/// Caseless: this is a namespace for pure functions, never a value.
public enum YouTubeOEmbed {
    /// How many lookups may be in flight at once.
    ///
    /// Every one of them is a request the listener did not explicitly make, so the
    /// fan-out stays small: enough that pasting a dozen links fills in quickly,
    /// low enough that a keyless public endpoint is not hammered.
    public static let maximumConcurrentFetches = 4

    /// The per-request budget, for BOTH the JSON lookup and a thumbnail fetch.
    ///
    /// Decoration must never outlive the moment it decorates. Five seconds is long
    /// enough for a cold DNS lookup on a slow link and short enough that a stalled
    /// endpoint cannot pin a permit — which is what keeps
    /// ``OEmbedConcurrencyGate`` free of a deadlock story.
    public static let requestTimeoutSeconds: TimeInterval = 5

    /// A body larger than this is refused unread.
    ///
    /// An oEmbed document is well under a kilobyte and a poster frame is tens of
    /// them; the ceiling exists so a redirected or hostile URL cannot stream
    /// unbounded into memory behind a `Data`-returning API.
    public static let maximumResponseBytes = 8 * 1024 * 1024

    /// The oEmbed endpoint's host — the same host the watch URL uses.
    public static let endpointHost = "www.youtube.com"

    /// The oEmbed endpoint's path.
    public static let endpointPath = "/oembed"

    /// RFC 3986 unreserved. Encoding the inner watch URL against this set — and
    /// nothing wider — is what turns it into ONE opaque query value.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// `https://www.youtube.com/oembed?url=<percent-encoded watch URL>&format=json`,
    /// or `nil` when `videoID` is not a well-formed id.
    ///
    /// The inner URL is built by ``YouTubeURLNormalizer/canonicalURL(forVideoID:)``
    /// rather than spelled again here, so the id validation and the canonical watch
    /// shape have exactly one definition in this module.
    ///
    /// `percentEncodedQuery` is load-bearing: interpolating the watch URL raw would
    /// let its own `?v=` and the trailing `&format=` bind to the OUTER query, and
    /// YouTube would be asked about a URL that stops at `/watch`.
    public static func requestURL(forVideoID videoID: String) -> URL? {
        guard let watchURL = YouTubeURLNormalizer.canonicalURL(forVideoID: videoID),
              let encoded = watchURL.absoluteString
              .addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpointHost
        components.path = endpointPath
        components.percentEncodedQuery = "url=\(encoded)&format=json"
        return components.url
    }

    /// The one place "did this lookup answer?" is decided.
    ///
    /// - Parameter response: `nil` when the request never completed (timeout, DNS
    ///   failure, offline).
    /// - Returns: `nil` for a `nil` response, any non-2xx status, an oversized
    ///   body, a body that is not JSON, and a payload whose title is empty. 404
    ///   (no such video), 401 (private or deleted) and a timeout are deliberately
    ///   indistinguishable: none of them is something a caller can act on.
    public static func payload(from response: OEmbedResponse?) -> OEmbedPayload? {
        guard let body = acceptedBody(from: response) else { return nil }
        guard let payload = try? JSONDecoder().decode(OEmbedPayload.self, from: body) else { return nil }
        return payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : payload
    }

    /// The same judgement for image bytes: a 2xx with a non-empty, in-budget body.
    public static func thumbnailData(from response: OEmbedResponse?) -> Data? {
        acceptedBody(from: response)
    }

    /// A thumbnail URL that is safe to spend a round-trip on, or `nil`.
    ///
    /// The URL arrives inside an untrusted body, so it is re-checked rather than
    /// trusted: `https` only, a real host, and no embedded credentials or port —
    /// the same shape rule the watch-URL validator applies. The host itself is NOT
    /// pinned to a CDN name: YouTube has moved poster frames between hosts before,
    /// and the size ceiling plus the 5 s budget already bound what a redirect can
    /// cost.
    public static func validatedThumbnailURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, host.isEmpty == false,
              components.user == nil, components.password == nil, components.port == nil
        else { return nil }
        return url
    }

    /// A 2xx, non-empty, in-budget body — or `nil`.
    private static func acceptedBody(from response: OEmbedResponse?) -> Data? {
        guard let response, (200 ..< 300).contains(response.statusCode) else { return nil }
        guard response.body.isEmpty == false, response.body.count <= maximumResponseBytes else { return nil }
        return response.body
    }
}

// MARK: - The concurrency window

/// A counting window that admits at most `capacity` lookups at a time.
///
/// An `actor` rather than a semaphore because nothing may block: a waiter parks on
/// a continuation and is resumed by the next release, so a full window costs a
/// suspension rather than a thread.
///
/// **Why there is no cancellation story.** A task cancelled while parked stays
/// parked until a permit frees. That can never be unbounded: every permit holder
/// is a request carrying ``YouTubeOEmbed/requestTimeoutSeconds``, so the longest a
/// waiter can wait is the depth of the queue times five seconds, and the body it
/// finally runs observes its own cancellation immediately. Adding a
/// cancellation-aware waiter registry would buy nothing that the transport's own
/// deadline does not already guarantee.
public actor OEmbedConcurrencyGate {
    private let capacity: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter capacity: The window. Clamped to at least one, so a caller
    ///   cannot accidentally configure a gate that admits nobody.
    public init(capacity: Int = YouTubeOEmbed.maximumConcurrentFetches) {
        self.capacity = max(1, capacity)
    }

    /// Runs `body` under one permit, waiting first when the window is full.
    public func withPermit<Value: Sendable>(_ body: @Sendable () async -> Value) async -> Value {
        await acquire()
        let value = await body()
        release()
        return value
    }

    private func acquire() async {
        guard inFlight >= capacity else {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the permit STRAIGHT to the longest-waiting caller rather than
    /// decrementing and letting it re-check. Decrementing first would let two
    /// releases wake two waiters against one freed slot, which is precisely the
    /// overshoot the window exists to prevent.
    private func release() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }
        inFlight -= 1
    }
}
