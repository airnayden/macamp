import Foundation
import Metadata
import Services

/// A network-free ``InfoPrefetching`` that records every cache probe and prefetch.
///
/// It exists to prove LANE PURITY in the enrichment pass: a track that probes as
/// already cached must never reach a prefetch, because prefetches queue behind the
/// shared MusicBrainz limiter and so must stay out of the parallel lyrics lane.
///
/// ``onPrefetchActivity`` fires `true` on entry and `false` on exit, so a test can
/// share one in-flight counter between this fake and its MusicBrainz fake and
/// assert the two never overlap. Pair it with `latency` — a zero-latency fake
/// never suspends, so an overlap could not be observed even if one existed.
public final class FakeInfoService: InfoPrefetching, @unchecked Sendable {
    private let lock = NSLock()
    private let cachedArtists: Set<String>
    private let cachesEverything: Bool
    private let latency: Duration
    private let onPrefetchActivity: (@Sendable (Bool) -> Void)?
    private var probes: [String?] = []
    private var titlePrefetches: [String] = []
    private var artistPrefetches: [String] = []

    /// - Parameters:
    ///   - cachedArtists: artist names whose info probes as already cached.
    ///   - cachesEverything: when `true`, every probe reports "already cached".
    ///   - latency: how long each prefetch suspends before returning.
    ///   - onPrefetchActivity: `true` when a prefetch begins, `false` when it ends.
    public init(
        cachedArtists: Set<String> = [],
        cachesEverything: Bool = false,
        latency: Duration = .zero,
        onPrefetchActivity: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.cachedArtists = cachedArtists
        self.cachesEverything = cachesEverything
        self.latency = latency
        self.onPrefetchActivity = onPrefetchActivity
    }

    /// The artist of every track ``hasCachedInfo(title:artist:)`` was asked about.
    public var probedArtists: [String?] {
        lock.withLock { probes }
    }

    public var probeCount: Int {
        lock.withLock { probes.count }
    }

    /// Titles handed to ``trackInfo(title:artist:mbid:)``, in call order.
    public var prefetchedTitles: [String] {
        lock.withLock { titlePrefetches }
    }

    /// Names handed to ``artistInfo(name:mbid:)``, in call order.
    public var prefetchedArtists: [String] {
        lock.withLock { artistPrefetches }
    }

    /// Total prefetch calls of both kinds — `0` proves nothing hit the limiter.
    public var prefetchCount: Int {
        lock.withLock { titlePrefetches.count + artistPrefetches.count }
    }

    public func hasCachedInfo(title: String?, artist: String?) async -> Bool {
        lock.withLock {
            probes.append(artist)
            if cachesEverything { return true }
            let title = title ?? ""
            let artist = artist ?? ""
            guard !title.isEmpty || !artist.isEmpty else { return true }
            return !artist.isEmpty && cachedArtists.contains(artist)
        }
    }

    public func artistInfo(name: String, mbid _: String?) async -> ArtistInfo? {
        lock.withLock { artistPrefetches.append(name) }
        await runPrefetch()
        return nil
    }

    public func trackInfo(title: String, artist _: String?, mbid _: String?) async -> TrackInfo? {
        lock.withLock { titlePrefetches.append(title) }
        await runPrefetch()
        return nil
    }

    private func runPrefetch() async {
        onPrefetchActivity?(true)
        defer { onPrefetchActivity?(false) }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
    }
}
