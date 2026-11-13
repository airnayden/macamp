// AtomicKaraokeQueueCoordinatorTests — queue replacement + karaoke engagement
// must resolve only the final queue and suppress the explicit-path miss toast.
import AudioEngine
import Foundation
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct AtomicKaraokeQueueCoordinatorTests {
    private static let modelSHA = "test-model-sha"

    private struct TempTrack {
        let ref: TrackRef
        let originalURL: URL
        let instrumentalURL: URL
        let key: SeparationCacheKey
    }

    private func makeTempTrack(_ name: String) throws -> TempTrack {
        let directory = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString
        let original = directory.appendingPathComponent("atomic-\(name)-\(stamp).flac")
        try Data("original-\(name)".utf8).write(to: original)
        let instrumental = directory.appendingPathComponent("atomic-\(name)-instrumental-\(stamp).m4a")
        try Data("instrumental-\(name)".utf8).write(to: instrumental)
        let ref = TrackRef(filePath: original.path, title: name)
        let key = try SeparationCacheKey(url: original, modelSHA: Self.modelSHA)
        return TempTrack(ref: ref, originalURL: original, instrumentalURL: instrumental, key: key)
    }

    private func makeCoordinator(
        cache: any InstrumentalCaching
    ) -> (PlaybackCoordinator, SpyPlaybackEngine) {
        let engine = SpyPlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 100))
        let coordinator = PlaybackCoordinator(
            engine: engine,
            instrumentalCache: cache,
            karaokeModelSHA: Self.modelSHA,
            karaokeSeparatorAvailable: true
        )
        coordinator.karaokeDebounceInterval = .milliseconds(20)
        return (coordinator, engine)
    }

    @Test("atomic queue engagement activates karaoke without an auto-deactivate callback")
    func atomicQueueEngagementActivatesSilently() async throws {
        let track = try makeTempTrack("ready")
        let cache = ResolutionCountingCache(seeded: [track.key: track.instrumentalURL])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.setQueue([track.ref], startingAt: 0, engagingKaraoke: true)
        await coordinator.karaokeDebounceTask?.value

        #expect(coordinator.karaokeActive)
        #expect(coordinator.state.karaokeActive)
        #expect(engine.reloadedURLs == [track.instrumentalURL])
        #expect(await cache.requestedKeys == [track.key])
        #expect(autoDeactivations == 0)
    }

    @Test("rapid atomic queue engagement resolves exactly once against the final queue")
    func rapidAtomicQueueEngagementUsesFinalQueue() async throws {
        let first = try makeTempTrack("first")
        let final = try makeTempTrack("final")
        let cache = ResolutionCountingCache(seeded: [
            first.key: first.instrumentalURL,
            final.key: final.instrumentalURL,
        ])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.setQueue([first.ref], startingAt: 0, engagingKaraoke: true)
        coordinator.setQueue([final.ref], startingAt: 0, engagingKaraoke: true)
        await coordinator.karaokeDebounceTask?.value

        #expect(coordinator.current == final.ref)
        #expect(coordinator.karaokeActive)
        #expect(engine.reloadedURLs == [final.instrumentalURL])
        #expect(await cache.requestedKeys == [final.key])
        #expect(autoDeactivations == 0)
    }

    @Test("an explicit atomic resolution miss deactivates karaoke silently")
    func atomicQueueMissSuppressesCallback() async throws {
        let track = try makeTempTrack("explicit-miss")
        let cache = ResolutionCountingCache(seeded: [:])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.setQueue([track.ref], startingAt: 0, engagingKaraoke: true)
        await coordinator.karaokeDebounceTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(!coordinator.state.karaokeActive)
        #expect(engine.loadedURLs == [track.originalURL])
        #expect(await cache.requestedKeys == [track.key])
        #expect(autoDeactivations == 0)
    }

    @Test("the same miss through normal toggle navigation still fires the callback")
    func normalToggleMissPreservesCallback() async throws {
        let track = try makeTempTrack("normal-miss")
        let cache = ResolutionCountingCache(seeded: [:])
        let (coordinator, engine) = makeCoordinator(cache: cache)
        var autoDeactivations = 0
        coordinator.onKaraokeAutoDeactivated = { autoDeactivations += 1 }

        coordinator.setQueue([track.ref], startingAt: 0)
        coordinator.toggleKaraoke()
        await coordinator.karaokeDebounceTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(!coordinator.state.karaokeActive)
        #expect(engine.loadedURLs == [track.originalURL])
        #expect(await cache.requestedKeys == [track.key])
        #expect(autoDeactivations == 1)
    }
}

private actor ResolutionCountingCache: InstrumentalCaching {
    private let base: FakeInstrumentalCache
    private(set) var requestedKeys: [SeparationCacheKey] = []

    init(seeded: [SeparationCacheKey: URL]) {
        base = FakeInstrumentalCache(seeded: seeded)
    }

    func cachedInstrumental(for key: SeparationCacheKey) async -> URL? {
        requestedKeys.append(key)
        return await base.cachedInstrumental(for: key)
    }

    func store(
        _ source: URL,
        for key: SeparationCacheKey,
        identity: SourceIdentity?
    ) async throws -> URL {
        try await base.store(source, for: key, identity: identity)
    }

    func recordSourceIdentity(for key: SeparationCacheKey, identity: SourceIdentity) async {
        await base.recordSourceIdentity(for: key, identity: identity)
    }

    func pin(_ key: SeparationCacheKey) async {
        await base.pin(key)
    }

    func unpin(_ key: SeparationCacheKey) async {
        await base.unpin(key)
    }

    var totalBytes: Int64 {
        get async { await base.totalBytes }
    }

    func clearAll() async throws {
        try await base.clearAll()
    }

    @discardableResult
    func remove(sourcePaths: [String]) async throws -> Int {
        try await base.remove(sourcePaths: sourcePaths)
    }

    func readySnapshot() async -> (sequence: Int, records: [ReadyRecord]) {
        await base.readySnapshot()
    }

    func setOnEntriesChanged(
        _ handler: (@Sendable (Int, [ReadyRecord]) -> Void)?
    ) async {
        await base.setOnEntriesChanged(handler)
    }

    func setMaxByteSize(_ newValue: Int64) async {
        await base.setMaxByteSize(newValue)
    }

    func relocate(to newDirectory: URL) async throws -> Bool {
        try await base.relocate(to: newDirectory)
    }
}
