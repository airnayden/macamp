import Foundation
import GRDB
import Metadata
import Persistence

// LyricsService — the production ``LyricsProviding`` that resolves a track's
// lyrics by precedence and caches the result.
//
// Precedence (highest first): embedded synced > sidecar `.lrc` > LRCLIB (opt-in)
// > embedded unsynced. Online fetch is OFF unless ``LyricsOptions/allowOnlineFetch``
// is set, so MacAMP never auto-fetches third-party lyrics without explicit consent.
//
// When caching is on, the value returned is the document the cache holds after the
// store — so a resolve that loses a write race against a higher-precedence writer
// returns that winner rather than its own losing candidate.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// A `Sendable` reader for sidecar `.lrc` files next to an audio file.
public protocol SidecarLyricsReading: Sendable {
    /// Returns the `.lrc` text at `url`, or `nil` when the file is absent/unreadable.
    func readSidecar(at url: URL) -> String?
}

/// The production ``SidecarLyricsReading`` reading from the real filesystem.
///
/// Stateless (no stored `FileManager`) so it stays `Sendable`.
public struct FileSidecarReader: SidecarLyricsReading {
    public init() {}

    public func readSidecar(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A ``SidecarLyricsReading`` returning fixed text — the test double.
public struct FakeSidecarReader: SidecarLyricsReading {
    private let contents: String?

    public init(_ contents: String? = nil) {
        self.contents = contents
    }

    public func readSidecar(at _: URL) -> String? {
        contents
    }
}

/// Resolves and caches a track's lyrics across the embedded / `.lrc` / online sources.
public struct LyricsService: LyricsProviding {
    private let embeddedReader: any EmbeddedLyricsReading
    private let sidecar: any SidecarLyricsReading
    private let lrclib: (any OnlineLyricsFetching)?
    private let cache: (any LyricsCaching)?

    /// Designated initialiser injecting every seam.
    public init(
        embeddedReader: any EmbeddedLyricsReading,
        sidecar: any SidecarLyricsReading = FileSidecarReader(),
        lrclib: (any OnlineLyricsFetching)? = nil,
        cache: (any LyricsCaching)? = nil
    ) {
        self.embeddedReader = embeddedReader
        self.sidecar = sidecar
        self.lrclib = lrclib
        self.cache = cache
    }

    /// Convenience initialiser wiring the Metadata embedded reader + GRDB cache.
    public init(
        metadataReader: any MetadataReading,
        database: AppDatabase,
        lrclib: (any OnlineLyricsFetching)? = nil
    ) {
        self.init(
            embeddedReader: MetadataEmbeddedLyricsReader(reader: metadataReader),
            sidecar: FileSidecarReader(),
            lrclib: lrclib,
            cache: GRDBLyricsCache(database)
        )
    }

    public func resolveLyrics(for request: LyricsRequest, options: LyricsOptions) async throws -> Lyrics? {
        if options.useCache, let cache, let cached = try cache.load(forKey: request.cacheKey) {
            return cached
        }
        let candidates = try await gatherCandidates(for: request, options: options)
        guard let resolved = Self.resolve(from: candidates) else { return nil }
        guard options.useCache, let cache else { return resolved }
        return try cache.store(resolved, forKey: request.cacheKey)
    }

    /// Writes the negative-result sentinel for `cacheKey`, when a cache is wired.
    ///
    /// Best-effort: a failed sentinel write is not worth failing a caller's pass
    /// over, since the only cost is that the track gets asked about again.
    public func noteOnlineNoMatch(forKey cacheKey: String) async {
        guard let cache else { return }
        try? cache.markNoLyrics(forKey: cacheKey)
    }

    private func gatherCandidates(for request: LyricsRequest, options: LyricsOptions) async throws -> [Lyrics] {
        var candidates: [Lyrics] = []
        if let url = request.trackURL, let embedded = try? embeddedReader.readEmbeddedLyrics(from: url) {
            candidates.append(contentsOf: Self.lyrics(fromEmbedded: embedded))
        }
        if let sidecarURL = request.sidecarURL,
           let text = sidecar.readSidecar(at: sidecarURL), !text.isEmpty
        {
            candidates.append(LRCParser.parse(text, source: .lrcFile))
        }
        if options.allowOnlineFetch, let lrclib {
            do {
                let result = try await lrclib.fetch(
                    artist: request.artist,
                    title: request.title,
                    album: request.album,
                    duration: request.duration
                )
                if let result, let lyrics = Self.lyrics(fromLRCLIB: result) {
                    candidates.append(lyrics)
                }
            } catch {
                try Task.checkCancellation()
                guard !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled,
                      !candidates.isEmpty
                else { throw error }
            }
        }
        return candidates
    }
}

// MARK: - Pure resolution + mapping (separate body keeps each under the lint cap)

public extension LyricsService {
    /// Picks the highest-precedence non-empty candidate (ties resolve to the first).
    static func resolve(from candidates: [Lyrics]) -> Lyrics? {
        candidates
            .filter { !$0.isEmpty }
            .max { $0.source.precedenceRank < $1.source.precedenceRank }
    }
}

extension LyricsService {
    /// Maps an ``EmbeddedLyrics`` blob into ranked candidate documents.
    static func lyrics(fromEmbedded embedded: EmbeddedLyrics) -> [Lyrics] {
        var result: [Lyrics] = []
        if let synced = embedded.synced, !synced.isEmpty {
            let parsed = LRCParser.parse(synced, source: .embeddedSynced)
            if parsed.isSynced {
                result.append(parsed)
            } else {
                result.append(plainLyrics(synced, source: .embeddedUnsynced))
            }
        }
        if let unsynced = embedded.unsynced, !unsynced.isEmpty {
            result.append(plainLyrics(unsynced, source: .embeddedUnsynced))
        }
        return result
    }

    /// Maps an ``OnlineLyricsResult`` into a candidate document, or `nil` (instrumental/empty).
    static func lyrics(fromLRCLIB result: OnlineLyricsResult) -> Lyrics? {
        if result.isInstrumental { return nil }
        if let synced = result.syncedLyrics, !synced.isEmpty {
            return LRCParser.parse(synced, source: .lrclib)
        }
        if let plain = result.plainLyrics, !plain.isEmpty {
            return plainLyrics(plain, source: .lrclib)
        }
        return nil
    }

    /// Wraps plain text into an unsynced ``Lyrics`` value (blank edges trimmed).
    static func plainLyrics(_ text: String, source: LyricsSource) -> Lyrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LyricLine(text: String($0)) }
        return Lyrics(lines: lines, source: source)
    }
}
