import Foundation
import Metadata

// LyricsProviding — the resolution seam plus its in-memory test doubles.
//
// Resolution precedence (highest first): embedded synced > sidecar `.lrc` >
// LRCLIB (opt-in) > embedded unsynced. The concrete orchestration lives in
// ``LyricsService``; this file defines the protocol callers depend on, the
// network/metadata seams it talks through, and the fakes/mocks for tests.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant)
// and MUST NOT make any live network call in a test path.

// MARK: - Request / options

/// Identifies a track for lyrics resolution.
///
/// ``cacheKey`` is derived (file path when available, otherwise a tag composite)
/// so callers never have to invent one — keeping the initialiser at five params.
public struct LyricsRequest: Sendable, Equatable {
    /// The audio file URL — used for the embedded read and sidecar `.lrc` lookup.
    public var trackURL: URL?
    /// Track title (LRCLIB query + cache key fallback).
    public var title: String?
    /// Track artist (LRCLIB query + cache key fallback).
    public var artist: String?
    /// Album title (LRCLIB query).
    public var album: String?
    /// Track duration in seconds (LRCLIB match refinement).
    public var duration: TimeInterval?

    public init(
        trackURL: URL? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.trackURL = trackURL
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// A stable key for the GRDB cache: the file path when present, else a
    /// `artist|title|album|duration` composite.
    public var cacheKey: String {
        if let path = trackURL?.path, !path.isEmpty {
            return path
        }
        let composite = [artist ?? "", title ?? "", album ?? ""]
        let seconds = duration.map { String(Int($0.rounded())) } ?? ""
        return (composite + [seconds]).joined(separator: "|")
    }

    /// The sidecar `.lrc` URL next to ``trackURL`` (same name, `.lrc` extension).
    public var sidecarURL: URL? {
        guard let trackURL else { return nil }
        return trackURL.deletingPathExtension().appendingPathExtension("lrc")
    }
}

/// Knobs controlling a resolution pass.
public struct LyricsOptions: Sendable, Equatable {
    /// When `true`, the resolver MAY query LRCLIB. Defaults to `false` (opt-in).
    public var allowOnlineFetch: Bool
    /// When `true`, the resolver reads/writes the GRDB cache. Defaults to `true`.
    public var useCache: Bool

    public init(allowOnlineFetch: Bool = false, useCache: Bool = true) {
        self.allowOnlineFetch = allowOnlineFetch
        self.useCache = useCache
    }

    /// Default options: cache on, online fetch OFF.
    public static let `default` = LyricsOptions()
    /// Strictly offline: never touch the network.
    public static let offline = LyricsOptions(allowOnlineFetch: false)
    /// Online opt-in: cache on, LRCLIB allowed.
    public static let online = LyricsOptions(allowOnlineFetch: true)
}

// MARK: - Resolution protocol

/// Resolves a track's lyrics, honouring precedence and the opt-in online policy.
public protocol LyricsProviding: Sendable {
    /// Resolves lyrics for `request`, or `nil` when none are found.
    func resolveLyrics(for request: LyricsRequest, options: LyricsOptions) async throws -> Lyrics?

    /// Records that an **online** lookup for `cacheKey` genuinely found nothing, so
    /// the track is not re-asked about on every later pass.
    ///
    /// The caller owns the predicate, because only the caller knows what its `nil`
    /// meant: a resolve that returned `nil` *without throwing* is a negative result;
    /// a throw is a transient failure and must leave no record at all. See
    /// ``LyricsCaching/markNoLyrics(forKey:)`` for the sentinel's precedence rules —
    /// it never overwrites an existing row, and any later real document overwrites it.
    func noteOnlineNoMatch(forKey cacheKey: String) async
}

public extension LyricsProviding {
    /// Default: record nothing. A provider with no cache has nowhere to put a
    /// negative result, so every conformer that does not opt in stays unchanged.
    func noteOnlineNoMatch(forKey _: String) async {}

    /// Convenience overload using ``LyricsOptions/default``.
    func resolveLyrics(for request: LyricsRequest) async throws -> Lyrics? {
        try await resolveLyrics(for: request, options: .default)
    }
}

// MARK: - Embedded lyrics seam (USLT / SYLT via Metadata)

/// Embedded lyrics extracted from a file's tags.
///
/// SFBAudioEngine surfaces only a single `lyrics` string (ID3 `USLT` / Vorbis
/// `LYRICS`); there is no separate `SYLT` accessor. We model the SYLT/USLT split
/// by *content*: a blob that carries `[mm:ss]` timestamps is treated as synced
/// (``synced``), otherwise as plain text (``unsynced``).
public struct EmbeddedLyrics: Sendable, Equatable {
    /// Synced (SYLT-style) lyric text in `.lrc` form, if present.
    public var synced: String?
    /// Unsynced (USLT) plain lyric text, if present.
    public var unsynced: String?

    public init(synced: String? = nil, unsynced: String? = nil) {
        self.synced = synced
        self.unsynced = unsynced
    }

    /// `true` when neither synced nor unsynced text is present.
    public var isEmpty: Bool {
        (synced?.isEmpty ?? true) && (unsynced?.isEmpty ?? true)
    }
}

/// A `Sendable` reader that extracts ``EmbeddedLyrics`` from an audio file.
public protocol EmbeddedLyricsReading: Sendable {
    /// Reads embedded lyrics from `url`, or `nil` when the file carries none.
    func readEmbeddedLyrics(from url: URL) throws -> EmbeddedLyrics?
}

/// The production ``EmbeddedLyricsReading`` — adapts a Metadata ``MetadataReading``.
///
/// It reads `TrackMetadata.lyrics` and classifies it as synced or unsynced via
/// ``LRCParser/containsTimestamps(_:)``.
public struct MetadataEmbeddedLyricsReader: EmbeddedLyricsReading {
    private let reader: any MetadataReading

    public init(reader: any MetadataReading) {
        self.reader = reader
    }

    public func readEmbeddedLyrics(from url: URL) throws -> EmbeddedLyrics? {
        let metadata = try reader.readMetadata(from: url)
        guard let lyrics = metadata.lyrics, !lyrics.isEmpty else { return nil }
        if LRCParser.containsTimestamps(lyrics) {
            return EmbeddedLyrics(synced: lyrics, unsynced: nil)
        }
        return EmbeddedLyrics(synced: nil, unsynced: lyrics)
    }
}

/// An ``EmbeddedLyricsReading`` returning fixed values — the test double.
public struct FakeEmbeddedLyricsReader: EmbeddedLyricsReading {
    private let embedded: EmbeddedLyrics?

    public init(_ embedded: EmbeddedLyrics? = nil) {
        self.embedded = embedded
    }

    public func readEmbeddedLyrics(from _: URL) throws -> EmbeddedLyrics? {
        embedded
    }
}

// MARK: - Online lyrics network seam

/// A lyrics payload returned by the online lyrics service.
public struct OnlineLyricsResult: Sendable, Equatable {
    /// Plain (unsynced) lyrics, if available.
    public var plainLyrics: String?
    /// Synced lyrics in `.lrc` form, if available.
    public var syncedLyrics: String?
    /// `true` for instrumental tracks (online service returns no lyric text).
    public var isInstrumental: Bool

    public init(plainLyrics: String? = nil, syncedLyrics: String? = nil, isInstrumental: Bool = false) {
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        self.isInstrumental = isInstrumental
    }
}

/// The mockable online lyrics fetch seam.
///
/// Production uses ``LRCLIBClient`` (real `URLSession`); tests use
/// ``MockOnlineLyricsFetcher`` so **no live network call is ever made in a test**.
public protocol OnlineLyricsFetching: Sendable {
    /// Fetches the best matching lyrics, or `nil` when the service has none.
    func fetch(
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> OnlineLyricsResult?
}

/// A canned ``OnlineLyricsFetching`` that records call counts and never hits the network.
public final class MockOnlineLyricsFetcher: OnlineLyricsFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: OnlineLyricsResult?
    private var calls = 0

    public init(returning result: OnlineLyricsResult? = nil) {
        self.result = result
    }

    /// Number of times ``fetch(artist:title:album:duration:)`` was invoked.
    public var fetchCount: Int {
        lock.withLock { calls }
    }

    public func fetch(
        artist _: String?,
        title _: String?,
        album _: String?,
        duration _: TimeInterval?
    ) async throws -> OnlineLyricsResult? {
        lock.withLock {
            calls += 1
            return result
        }
    }
}

// MARK: - Fake provider

/// A canned ``LyricsProviding`` for previews and higher-layer tests.
public final class FakeLyricsProvider: LyricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var canned: Lyrics?
    private var seen: [LyricsRequest] = []

    public init(returning lyrics: Lyrics? = nil) {
        canned = lyrics
    }

    /// The requests this provider has been asked to resolve, in order.
    public var requests: [LyricsRequest] {
        lock.withLock { seen }
    }

    /// Replaces the canned result returned by future resolutions.
    public func setLyrics(_ lyrics: Lyrics?) {
        lock.withLock { canned = lyrics }
    }

    public func resolveLyrics(for request: LyricsRequest, options _: LyricsOptions) async throws -> Lyrics? {
        lock.withLock {
            seen.append(request)
            return canned
        }
    }
}
