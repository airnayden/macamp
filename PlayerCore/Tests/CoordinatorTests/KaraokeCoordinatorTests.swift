// KaraokeCoordinatorTests — the karaoke source-resolution + mid-song toggle
// contract (todo 12), driven through ``SpyPlaybackEngine`` (records reloads) and a
// seeded ``FakeInstrumentalCache``. Real temp files back each ``TrackRef`` so the
// coordinator's on-disk ``SeparationCacheKey`` derivation matches the seeded keys.
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
struct KaraokeCoordinatorTests {
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
        let original = dir.appendingPathComponent("karaoke-\(name)-\(stamp).flac")
        try Data("original-\(name)".utf8).write(to: original)
        let instrumental = dir.appendingPathComponent("karaoke-\(name)-instr-\(stamp).m4a")
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

    // MARK: (a) cache-hit toggle ⇒ one reload, position + play-state preserved

    @Test("(a) a cache-hit toggle issues exactly one reload preserving position and play-state")
    func cacheHitToggleReloadsOnce() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        coordinator.setQueue([trackA.ref], startingAt: 0)
        coordinator.seek(to: 12.5)

        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value

        #expect(engine.reloadedURLs == [trackA.instrumentalURL])
        #expect(coordinator.karaokeActive)
        #expect(abs(coordinator.currentTime - 12.5) < 0.1)
        #expect(coordinator.state.playback == .playing)
    }

    // MARK: (b) toggle spam ⇒ ≤ 2 reloads

    @Test("(b) five rapid toggles coalesce to at most two reloads")
    func rapidTogglesCoalesce() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        coordinator.setQueue([trackA.ref], startingAt: 0)

        for _ in 0 ..< 5 {
            coordinator.toggleKaraoke()
        }
        await coordinator.karaokeDebounceTask?.value

        #expect(engine.reloadedURLs.count <= 2)
    }

    // MARK: (c) preschedule enqueues instrumental when cached, else original

    @Test("(c) preschedule enqueues the instrumental successor when cached, the original otherwise")
    func prescheduleEnqueuesResolvedSuccessor() async throws {
        let trackA = try makeTempTrack("a")
        let trackB = try makeTempTrack("b")

        let hitCache = FakeInstrumentalCache(seeded: [
            trackA.key: trackA.instrumentalURL,
            trackB.key: trackB.instrumentalURL,
        ])
        let (hit, hitEngine) = makeCoordinator(cache: hitCache)
        hit.setQueue([trackA.ref, trackB.ref], startingAt: 0)
        hit.setKaraokeActive(true)
        await hit.karaokeDebounceTask?.value
        #expect(hitEngine.enqueuedURLs == [trackB.instrumentalURL])

        let missCache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (miss, missEngine) = makeCoordinator(cache: missCache)
        miss.setQueue([trackA.ref, trackB.ref], startingAt: 0)
        miss.setKaraokeActive(true)
        await miss.karaokeDebounceTask?.value
        #expect(missEngine.enqueuedURLs == [trackB.originalURL])
    }

    // MARK: (d) snapshot persists only the boolean; old snapshots decode false

    @Test("(d) a snapshot carries only karaokeActive, never a cache path, and legacy snapshots decode false")
    func snapshotPersistsBooleanNotCachePath() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (coordinator, _) = makeCoordinator(cache: cache)
        coordinator.setQueue([trackA.ref], startingAt: 0)
        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value
        #expect(coordinator.karaokeActive)

        let snap = coordinator.snapshot()
        #expect(snap.karaokeActive)
        #expect(snap.entries.map(\.filePath) == [trackA.originalURL.path])

        let encoded = try JSONEncoder().encode(snap)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains(trackA.instrumentalURL.lastPathComponent))
        #expect(!json.contains(InstrumentalCacheLocation.applicationSupportSubpath))

        let decoded = try JSONDecoder().decode(CoordinatorSnapshot.self, from: encoded)
        #expect(decoded.karaokeActive)

        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "karaokeActive")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let legacyDecoded = try JSONDecoder().decode(CoordinatorSnapshot.self, from: legacy)
        #expect(!legacyDecoded.karaokeActive)
    }

    // MARK: (e) restore of a karaoke snapshot loads the cached instrumental

    @Test("(e) restoring a karaoke snapshot resolves the current track through the instrumental seam")
    func restoreLoadsInstrumentalWhenActiveAndCached() async throws {
        let trackA = try makeTempTrack("a")
        let cache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let snap = CoordinatorSnapshot(
            entries: [trackA.ref],
            order: [trackA.ref.id],
            currentID: trackA.ref.id,
            shuffle: false,
            repeatMode: .off,
            position: 8.0,
            karaokeActive: true
        )
        let (coordinator, engine) = makeCoordinator(cache: cache)

        coordinator.restore(from: snap)
        await coordinator.karaokeRestoreTask?.value

        #expect(engine.loadedURLs == [trackA.instrumentalURL])
        #expect(coordinator.karaokeActive)
        #expect(abs(coordinator.currentTime - 8.0) < 0.1)
    }

    // MARK: (f) missing track / unavailable separator ⇒ no reload, disabled state

    @Test("(f) a toggle is a no-op surfaced as disabled when the separator or track is unavailable")
    func toggleNoOpWhenUnavailable() async throws {
        let trackA = try makeTempTrack("a")
        let unavailableCache = FakeInstrumentalCache(seeded: [trackA.key: trackA.instrumentalURL])
        let (noSeparator, noSeparatorEngine) = makeCoordinator(cache: unavailableCache, separatorAvailable: false)
        noSeparator.setQueue([trackA.ref], startingAt: 0)
        noSeparator.setKaraokeActive(true)
        await noSeparator.karaokeDebounceTask?.value
        #expect(noSeparatorEngine.reloadedURLs.isEmpty)
        #expect(!noSeparator.karaokeActive)
        #expect(!noSeparator.state.karaokeActive)

        let missing = try makeTempTrack("m", availability: .missing)
        let missingCache = FakeInstrumentalCache(seeded: [missing.key: missing.instrumentalURL])
        let (coordinator, engine) = makeCoordinator(cache: missingCache)
        coordinator.setQueue([missing.ref], startingAt: 0)
        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value
        #expect(engine.reloadedURLs.isEmpty)
        #expect(!coordinator.karaokeActive)
    }

    // MARK: (g) mid-song toggle resets lastScheduledNextID and re-enqueues the new variant

    @Test("(g) toggling mid-song resets lastScheduledNextID and re-enqueues the successor's new variant")
    func toggleReenqueuesSuccessorVariant() async throws {
        let trackA = try makeTempTrack("a")
        let trackB = try makeTempTrack("b")
        let cache = FakeInstrumentalCache(seeded: [
            trackA.key: trackA.instrumentalURL,
            trackB.key: trackB.instrumentalURL,
        ])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        coordinator.setQueue([trackA.ref, trackB.ref], startingAt: 0)

        coordinator.prescheduleNextIfNeeded()
        #expect(engine.enqueuedURLs == [trackB.originalURL])
        #expect(coordinator.lastScheduledNextID == trackB.ref.id)

        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value

        #expect(engine.enqueuedURLs == [trackB.originalURL, trackB.instrumentalURL])
        #expect(coordinator.lastScheduledNextID == trackB.ref.id)
    }
}
