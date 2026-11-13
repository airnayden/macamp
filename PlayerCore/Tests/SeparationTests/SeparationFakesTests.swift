// Smoke coverage for the Separation test doubles. Nine downstream todos build on
// `FakeStemSeparator` / `FakeInstrumentalCache` / `FakeKaraokeRenderer`, so this
// proves they compile against the protocols and behave as advertised (progress
// plumbing, cache round-trip, request recording) before those todos depend on them.
import Foundation
import PlayerCoreTestSupport
@testable import Separation
import Testing

@Suite("Separation fakes")
struct SeparationFakesTests {
    @Test("separator returns its configured output and reports 0→1 progress")
    func separatorSucceeds() async throws {
        let output = URL(fileURLWithPath: "/tmp/instrumental.m4a")
        let separator = FakeStemSeparator(returning: output)
        let collector = ProgressCollector()

        let result = try await separator.separate(url: URL(fileURLWithPath: "/tmp/in.flac")) { fraction in
            collector.append(fraction)
        }

        #expect(result == output)
        #expect(collector.values.first == 0)
        #expect(collector.values.last == 1)
        #expect(separator.separateCallCount == 1)
        #expect(await separator.availability.isAvailable)
    }

    @Test("separator throws modelUnavailable when configured unavailable")
    func separatorUnavailableThrows() async {
        let separator = FakeStemSeparator(availability: .unavailable(reason: .modelNotBundled))
        await #expect(throws: SeparationError.modelUnavailable) {
            _ = try await separator.separate(url: URL(fileURLWithPath: "/tmp/in.flac"))
        }
    }

    @Test("cache round-trips store → lookup, honors pins, and clears")
    func cacheRoundTrip() async throws {
        let cache = FakeInstrumentalCache()
        let key = SeparationCacheKey(canonicalPath: "/m/a.flac", fileSize: 1, mtime: 2, modelSHA: "m")
        let stored = URL(fileURLWithPath: "/tmp/a.m4a")

        #expect(await cache.cachedInstrumental(for: key) == nil)
        _ = try await cache.store(stored, for: key)
        #expect(await cache.cachedInstrumental(for: key) == stored)

        await cache.pin(key)
        #expect(await cache.isPinned(key))
        await cache.unpin(key)
        #expect(await cache.isPinned(key) == false)

        await cache.setByteSize(2048, for: key)
        #expect(await cache.totalBytes == 2048)

        try await cache.clearAll()
        #expect(await cache.cachedInstrumental(for: key) == nil)
        #expect(await cache.totalBytes == 0)
    }

    /// Parity with `InstrumentalCache.remove(sourcePaths:)`: pinned entries survive, the
    /// return value counts only what was deleted, and every requested path is recorded
    /// (even the skipped one) so a UI test can assert what was asked for.
    @Test("cache fake removes unpinned entries by source path, skips pinned, and records requests")
    func cacheRemovesBySourcePath() async throws {
        let cache = FakeInstrumentalCache()
        let removableKey = SeparationCacheKey(canonicalPath: "/m/a.flac", fileSize: 1, mtime: 2, modelSHA: "m")
        let pinnedKey = SeparationCacheKey(canonicalPath: "/m/b.flac", fileSize: 1, mtime: 2, modelSHA: "m")
        _ = try await cache.store(
            URL(fileURLWithPath: "/tmp/a.m4a"),
            for: removableKey,
            identity: SourceIdentity(path: "/m/a.flac", fileSize: 1, mtime: 2)
        )
        _ = try await cache.store(
            URL(fileURLWithPath: "/tmp/b.m4a"),
            for: pinnedKey,
            identity: SourceIdentity(path: "/m/b.flac", fileSize: 1, mtime: 2)
        )
        await cache.pin(pinnedKey)

        let removed = try await cache.remove(sourcePaths: ["/m/a.flac", "/m/b.flac"])

        #expect(removed == 1)
        #expect(await cache.contains(removableKey) == false)
        #expect(await cache.contains(pinnedKey)) // pinned survives, exactly like production
        #expect(await cache.removedSourcePaths == ["/m/a.flac", "/m/b.flac"])
    }

    @Test("renderer records enable + requests and emits progress + finish")
    @MainActor
    func rendererRecords() {
        let renderer = FakeKaraokeRenderer()
        renderer.setEnabled(true)
        #expect(renderer.isEnabled)

        let first = URL(fileURLWithPath: "/tmp/now.flac")
        let second = URL(fileURLWithPath: "/tmp/next.flac")
        renderer.requestRender(first)
        renderer.requestRender(second)
        #expect(renderer.requestedURLs == [first, second])
        #expect(renderer.requestRenderCallCount == 2)

        let progressSink = ProgressCollector()
        renderer.onProgress = { progressSink.append($0.fraction) }
        renderer.emit(KaraokePrewarmProgress(url: first, fraction: 0.5))
        #expect(progressSink.values == [0.5])

        let finishSink = FinishRecorder()
        renderer.onFinished = { _, result in finishSink.append(result) }
        renderer.finish(first, result: .rendered)
        #expect(finishSink.values == [.rendered])
    }
}

/// A thread-safe `Double` collector for the `@Sendable` progress closures.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ fraction: Double) {
        lock.withLock { storage.append(fraction) }
    }

    var values: [Double] {
        lock.withLock { storage }
    }
}

/// A thread-safe result collector for the `@Sendable` `onFinished` closure.
private final class FinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KaraokeRenderResult] = []

    func append(_ result: KaraokeRenderResult) {
        lock.withLock { storage.append(result) }
    }

    var values: [KaraokeRenderResult] {
        lock.withLock { storage }
    }
}
