// KaraokeHonestyCoordinatorTests — the coordinator NEVER plays the original while
// claiming karaoke is active (todo 8). It is strictly cache-read-only (no reachable
// `StemSeparating`), and auto-deactivates whenever the current track has no resolved
// instrumental — on activation-miss, an advance onto an uncached track, and (silently)
// on restore. Real temp files back each ``TrackRef`` so on-disk ``SeparationCacheKey``
// derivation matches the seeded keys.
import AudioEngine
import Foundation
import Models
import Persistence
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct KaraokeHonestyCoordinatorTests {
    private static let modelSHA = "test-model-sha"

    private struct TempTrack {
        let ref: TrackRef
        let originalURL: URL
        let instrumentalURL: URL
        let key: SeparationCacheKey
    }

    private func makeTempTrack(_ name: String, availability: Availability = .present) throws -> TempTrack {
        let dir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString
        let original = dir.appendingPathComponent("honesty-\(name)-\(stamp).flac")
        try Data("original-\(name)".utf8).write(to: original)
        let instrumental = dir.appendingPathComponent("honesty-\(name)-instr-\(stamp).m4a")
        try Data("instrumental-\(name)".utf8).write(to: instrumental)
        let ref = TrackRef(filePath: original.path, title: name, availability: availability)
        let key = try SeparationCacheKey(url: original, modelSHA: Self.modelSHA)
        return TempTrack(ref: ref, originalURL: original, instrumentalURL: instrumental, key: key)
    }

    private func makeCoordinator(
        cache: any InstrumentalCaching,
        separatorAvailable: Bool = true,
        debounce: Duration = .milliseconds(20)
    ) -> (PlaybackCoordinator, SpyPlaybackEngine) {
        let engine = SpyPlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 100))
        let coordinator = PlaybackCoordinator(
            engine: engine,
            instrumentalCache: cache,
            karaokeModelSHA: Self.modelSHA,
            karaokeSeparatorAvailable: separatorAvailable
        )
        coordinator.karaokeDebounceInterval = debounce
        return (coordinator, engine)
    }

    private func snapshot(_ track: TempTrack, position: TimeInterval) -> CoordinatorSnapshot {
        CoordinatorSnapshot(
            entries: [track.ref],
            order: [track.ref.id],
            currentID: track.ref.id,
            shuffle: false,
            repeatMode: .off,
            position: position,
            karaokeActive: true
        )
    }

    // (a) restore + warm cache ⇒ instrumental plays, zero separator involvement

    @Test("(a) restoring an active snapshot with a warm cache plays the instrumental, read-only")
    func restoreWarmCachePlaysInstrumentalCacheReadOnly() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.restore(from: snapshot(trackA, position: 8.0))
        await coordinator.karaokeRestoreTask?.value

        #expect(engine.loadedURLs == [trackA.instrumentalURL])
        #expect(coordinator.karaokeActive)
        #expect(coordinator.state.karaokeActive)
        #expect(autoDeactivations == 0)
        // The coordinator has no reachable ``StemSeparating``; a render would call
        // `store`, so zero stores/clears proves it never triggered a render.
        let stores = await cache.storeCallCount
        let clears = await cache.clearCallCount
        #expect(stores == 0)
        #expect(clears == 0)
    }

    // (b) advance cached ⇒ uncached while active ⇒ auto-deactivate + seam once

    @Test("(b) advancing onto an uncached track while active auto-deactivates and fires the seam once")
    func advanceToUncachedAutoDeactivates() async throws {
        let trackA = try makeTempTrack("a")
        let trackB = try makeTempTrack("b")
        let cache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.setQueue([trackA.ref, trackB.ref], startingAt: 0)
        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value
        #expect(coordinator.karaokeActive)
        #expect(engine.reloadedURLs == [trackA.instrumentalURL])

        coordinator.next()
        await coordinator.karaokeWarmTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(!coordinator.state.karaokeActive)
        #expect(autoDeactivations == 1)
        #expect(engine.loadedURLs.last == trackB.originalURL)
    }

    // (c) activate with an empty cache ⇒ settles inactive + seam; original only under inactive

    @Test("(c) activating with an empty cache settles inactive, fires the seam, never plays original as active")
    func activateWithEmptyCacheAutoDeactivates() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [:])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.setQueue([trackA.ref], startingAt: 0)
        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(!coordinator.state.karaokeActive)
        #expect(autoDeactivations == 1)
        #expect(engine.reloadedURLs.isEmpty)
        #expect(engine.loadedURLs == [trackA.originalURL])
    }

    // (d) restore + empty/stale cache ⇒ silently settles inactive, plays original

    @Test("(d) restoring an active snapshot with an empty cache silently settles inactive and plays original")
    func restoreEmptyCacheSilentlyDeactivates() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [:])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.restore(from: snapshot(trackA, position: 5.0))
        await coordinator.karaokeRestoreTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(!coordinator.state.karaokeActive)
        #expect(engine.loadedURLs == [trackA.originalURL])
        #expect(abs(coordinator.currentTime - 5.0) < 0.1)
        #expect(autoDeactivations == 0)
        let stores = await cache.storeCallCount
        #expect(stores == 0)
    }

    // (e) restore + uncapable stack (nil cache) ⇒ silently settles inactive

    @Test("(e) restoring an active snapshot with no cache stack silently settles inactive")
    func restoreUncapableStackSilentlyDeactivates() async throws {
        let trackA = try makeTempTrack("a")
        let engine = SpyPlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 100))
        let coordinator = PlaybackCoordinator(
            engine: engine,
            instrumentalCache: nil,
            karaokeModelSHA: Self.modelSHA,
            karaokeSeparatorAvailable: false
        )
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.restore(from: snapshot(trackA, position: 3.0))
        await coordinator.karaokeRestoreTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(!coordinator.state.karaokeActive)
        #expect(engine.loadedURLs == [trackA.originalURL])
        #expect(abs(coordinator.currentTime - 3.0) < 0.1)
        #expect(autoDeactivations == 0)
    }
}
