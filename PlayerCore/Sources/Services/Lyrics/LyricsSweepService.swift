// LyricsSweepService — the background offline fill of the lyrics cache.
//
// It walks the present library in bounded `id`-keyset chunks and resolves each
// track's lyrics from **offline sources only** (embedded tags + `.lrc` sidecars).
// It NEVER touches the network: the pass runs with
// ``LyricsOptions/allowOnlineFetch`` off, so an injected online fetcher is never
// called even when one is wired.
//
// Every probed track leaves a row behind — the resolved document, or a
// negative-result sentinel (``LyricsCaching/markNoLyrics(forKey:)``) when the file
// carries none. The repository anti-join then skips it forever, so a re-run does
// zero work and a cancelled pass resumes where it stopped.
//
// The pass runs **one at a time, not once per process**: `start()` is a no-op only
// while a pass is in flight. A launch on which the user first adds a library folder
// refreshes the roots AFTER the launch pass has already finished, and a
// latched-forever service would leave every one of those tracks unprobed until the
// next relaunch — the exact "it doesn't automatically show all available lyrics"
// symptom. Re-running is cheap: the anti-join returns an empty first page once
// everything is probed.
//
// A pass that caches a document announces it through ``onDidCacheLyrics`` so the
// lyrics browser can refresh. The signal fires ONLY for a real document, never for
// a sentinel — a 100k-track library with no local lyrics emits nothing at all.
//
// Known, accepted limitation: lyrics embedded into a file AFTER its probe are not
// re-discovered here (the cache key is the path, not the mtime). Enrichment or
// opening the song's lyrics panel still finds them.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Lyrics
import os
import Persistence

/// Drives the background, offline-only fill of the lyrics cache.
///
/// `@MainActor` because the composition root starts it from the main actor after
/// the initial library load; all of the work is offloaded to a detached task.
@MainActor
public protocol LyricsSweeping: AnyObject {
    /// Called after the pass caches a track's lyrics — never for a sentinel.
    ///
    /// Fires off the main actor (the pass is detached), so consumers must hop.
    /// It is read once, when ``start()`` builds the pass.
    var onDidCacheLyrics: (@Sendable () -> Void)? { get set }

    /// Starts a sweep pass. A no-op while a pass is already running.
    func start()

    /// Cancels a running pass at the next track boundary. Rows written so far stay
    /// committed, and the next pass resumes from them.
    func cancel()
}

/// The production ``LyricsSweeping`` over the GRDB library and lyrics cache.
@MainActor
public final class LyricsSweepService: LyricsSweeping {
    public var onDidCacheLyrics: (@Sendable () -> Void)?

    private let repository: TrackRepository
    private let provider: any LyricsProviding
    private let cache: any LyricsCaching
    private let chunkSize: Int
    private var task: Task<Void, Never>?

    public init(
        repository: TrackRepository,
        lyricsProvider: any LyricsProviding,
        cache: any LyricsCaching,
        chunkSize: Int = 50
    ) {
        self.repository = repository
        provider = lyricsProvider
        self.cache = cache
        self.chunkSize = max(1, chunkSize)
    }

    /// Convenience initialiser wiring the GRDB repository + lyrics cache.
    public convenience init(
        database: AppDatabase,
        lyricsProvider: any LyricsProviding,
        chunkSize: Int = 50
    ) {
        self.init(
            repository: TrackRepository(database),
            lyricsProvider: lyricsProvider,
            cache: GRDBLyricsCache(database),
            chunkSize: chunkSize
        )
    }

    /// Starts a pass unless one is in flight.
    ///
    /// `task` is a main-actor supervisor rather than the walk itself: the walk is
    /// `Task.detached` (so it carries no actor isolation), and a detached task does
    /// NOT inherit cancellation — the explicit handler is what makes ``cancel()``
    /// reach it. The supervisor clearing `task` on the way out is what re-arms
    /// ``start()`` for the next roots refresh.
    public func start() {
        guard task == nil else { return }
        let pass = SweepPass(
            repository: repository,
            provider: provider,
            cache: cache,
            chunkSize: chunkSize,
            onDidCacheLyrics: onDidCacheLyrics
        )
        task = Task { @MainActor [weak self] in
            let walk = Task.detached(priority: .utility) { await pass.run() }
            await withTaskCancellationHandler {
                await walk.value
            } onCancel: {
                walk.cancel()
            }
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
    }

    /// Test/synchronization seam: returns once the started pass has finished.
    public func waitForCompletion() async {
        await task?.value
    }
}

/// The walk itself: an immutable value so the detached task carries no actor
/// isolation and no shared mutable state.
private struct SweepPass {
    let repository: TrackRepository
    let provider: any LyricsProviding
    let cache: any LyricsCaching
    let chunkSize: Int
    let onDidCacheLyrics: (@Sendable () -> Void)?

    private static let log = Logger(subsystem: "si.macamp.MacAMP", category: "lyrics-sweep")

    func run() async {
        var anchor: Int64?
        var probed = 0
        while !Task.isCancelled {
            guard let chunk = try? await repository.filePathsWithoutLyricsProbe(
                after: anchor,
                limit: chunkSize
            ), !chunk.isEmpty else { break }
            do {
                try Task.checkCancellation()
            } catch {
                break
            }
            probed += await probeSerially(chunk)
            anchor = chunk.last?.id
        }
        Self.log.debug("offline lyrics sweep finished after \(probed, privacy: .public) tracks")
    }

    /// Probes one chunk at concurrency 1 — the work is file I/O heavy — and
    /// returns how many tracks it got through before any cancellation.
    private func probeSerially(_ chunk: [UnprobedLyricsTrack]) async -> Int {
        var probed = 0
        for candidate in chunk {
            if Task.isCancelled { return probed }
            await probe(candidate)
            probed += 1
        }
        return probed
    }

    private func probe(_ candidate: UnprobedLyricsTrack) async {
        let request = LyricsRequest(trackURL: URL(fileURLWithPath: candidate.filePath))
        let resolved: Lyrics?
        do {
            resolved = try await provider.resolveLyrics(for: request, options: Self.offlineOptions)
        } catch {
            // A transient read failure is not a negative result: leaving the row
            // absent re-probes the track next launch instead of hiding it forever.
            Self.log.debug("offline lyrics probe failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard resolved == nil else {
            // `resolveLyrics` already stored the document (the pass runs with
            // `useCache`), so a row now exists that the browse join can see.
            onDidCacheLyrics?()
            return
        }
        try? cache.markNoLyrics(forKey: request.cacheKey)
    }

    /// Cache on, network **off** — the sweep's defining constraint.
    private static let offlineOptions = LyricsOptions(allowOnlineFetch: false, useCache: true)
}
