// InfoService — coordinates online-info fetch + cache (cache-first, fetch on miss).
//
// The single entry point the UI (and the enrichment pass) uses to obtain narrative
// info. Each accessor checks the ``InfoCacheStore`` first; on a miss it asks the
// injected ``OnlineInfoFetching`` and, on success, writes the result back so the
// next read is instant. Errors are swallowed (returns `nil`) — info is strictly
// best-effort and never surfaces a failure to the caller.
//
// A `Sendable` struct with `async` accessors: every cache + network operation
// suspends off whatever actor calls it (the UI calls it from a `.task`, the
// enrichment pass from its background Task), so nothing blocks the main thread.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Metadata
import Persistence

/// The narrow slice of ``InfoService`` the enrichment pass depends on: a cache
/// probe plus the two prefetch entry points it calls.
///
/// `albumInfo` is deliberately **not** a member — the Info panel and album detail
/// view call it directly on the concrete ``InfoService``, and widening this
/// protocol would force every fake to implement a method enrichment never uses.
///
/// `Sendable` is required: the conformer is stored by the `@MainActor`
/// ``EnrichmentService`` and awaited from its background pass.
public protocol InfoPrefetching: Sendable {
    /// `true` when prefetching this track would perform **no** network request —
    /// i.e. every lookup ``EnrichmentService`` would make is already cached (or
    /// is a no-op because the key is blank).
    ///
    /// This is the gate that keeps rate-limited info work out of the parallel
    /// lyrics lane: a track that probes `true` needs nothing from the serial lane.
    func hasCachedInfo(title: String?, artist: String?) async -> Bool

    func artistInfo(name: String, mbid: String?) async -> ArtistInfo?
    func trackInfo(title: String, artist: String?, mbid: String?) async -> TrackInfo?
}

/// Resolves and caches narrative info for artists, albums, and tracks.
public struct InfoService: InfoPrefetching {
    private let fetcher: any OnlineInfoFetching
    private let cache: InfoCacheStore

    public init(fetcher: any OnlineInfoFetching, cache: InfoCacheStore) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// Convenience initialiser wiring a default-expiry GRDB cache over `database`.
    public init(fetcher: any OnlineInfoFetching, database: AppDatabase) {
        self.init(fetcher: fetcher, cache: InfoCacheStore(database))
    }

    public func hasCachedInfo(title: String?, artist: String?) async -> Bool {
        let trackKey = Self.pairKey(primary: title ?? "", secondary: artist)
        if !trackKey.isEmpty, await cached(TrackInfo.self, entityType: Self.trackType, key: trackKey) == nil {
            return false
        }
        let artistKey = Self.artistKey(name: artist ?? "")
        if !artistKey.isEmpty, await cached(ArtistInfo.self, entityType: Self.artistType, key: artistKey) == nil {
            return false
        }
        return true
    }

    public func artistInfo(name: String, mbid: String?) async -> ArtistInfo? {
        let key = Self.artistKey(name: name)
        guard !key.isEmpty else { return nil }
        if let cached = try? await cache.load(ArtistInfo.self, entityType: Self.artistType, entityKey: key) {
            return cached
        }
        guard let info = try? await fetcher.fetchArtistInfo(name: name, mbid: mbid), !info.isEmpty else {
            return nil
        }
        try? await cache.store(info, entityType: Self.artistType, entityKey: key)
        return info
    }

    public func albumInfo(title: String, artist: String?, mbid: String?) async -> AlbumInfo? {
        let key = Self.pairKey(primary: title, secondary: artist)
        guard !key.isEmpty else { return nil }
        if let cached = try? await cache.load(AlbumInfo.self, entityType: Self.albumType, entityKey: key) {
            return cached
        }
        guard let info = try? await fetcher.fetchAlbumInfo(title: title, artist: artist, mbid: mbid),
              !info.isEmpty else { return nil }
        try? await cache.store(info, entityType: Self.albumType, entityKey: key)
        return info
    }

    public func trackInfo(title: String, artist: String?, mbid: String?) async -> TrackInfo? {
        let key = Self.pairKey(primary: title, secondary: artist)
        guard !key.isEmpty else { return nil }
        if let cached = try? await cache.load(TrackInfo.self, entityType: Self.trackType, entityKey: key) {
            return cached
        }
        guard let info = try? await fetcher.fetchTrackInfo(title: title, artist: artist, mbid: mbid),
              !info.isEmpty else { return nil }
        try? await cache.store(info, entityType: Self.trackType, entityKey: key)
        return info
    }
}

// MARK: - Cache probe

private extension InfoService {
    /// Flattens ``InfoCacheStore/load(_:entityType:entityKey:now:)``'s throwing
    /// double-optional into a single optional: a thrown error, an absent row and
    /// an expired row all read as "not cached".
    func cached<Value: Decodable & Sendable>(_ type: Value.Type, entityType: String, key: String) async -> Value? {
        let loaded = try? await cache.load(type, entityType: entityType, entityKey: key)
        return loaded ?? nil
    }
}

// MARK: - Cache keys (pure)

extension InfoService {
    static let artistType = "artist"
    static let albumType = "album"
    static let trackType = "track"

    /// The artist cache key: the trimmed artist name.
    static func artistKey(name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The album/track cache key: `"artist|primary"` (empty when the primary is blank).
    static func pairKey(primary: String, secondary: String?) -> String {
        let main = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !main.isEmpty else { return "" }
        let other = (secondary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(other)|\(main)"
    }
}
