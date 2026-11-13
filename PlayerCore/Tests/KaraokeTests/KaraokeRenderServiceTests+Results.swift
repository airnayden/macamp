import Foundation
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

extension KaraokeRenderServiceTests {
    @Test("a cache hit reports alreadyCached and records its source identity")
    func cachedURLReportsAlreadyCachedAndRecordsIdentity() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let identity = try SeparationCacheKey.sourceIdentity(for: files[0])
        let key = SeparationCacheKey(identity: identity, modelSHA: Self.modelSHA)
        let cachedURL = files[0].deletingLastPathComponent().appendingPathComponent("cached.m4a")
        let cache = FakeInstrumentalCache(seeded: [key: cachedURL])
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = KaraokeRenderResultCollector()
        let service = KaraokeRenderService(separator: separator, cache: cache, modelSHA: Self.modelSHA)
        service.onFinished = { collector.record(url: $0, result: $1) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { !collector.events.isEmpty }

        #expect(separator.separateCallCount == 0)
        #expect(collector.events == [KaraokeRenderResultEvent(url: files[0], result: .alreadyCached)])
        let snapshot = await cache.readySnapshot()
        #expect(snapshot.sequence == 1)
        #expect(snapshot.records == [Self.readyRecord(identity: identity, key: key)])
    }

    @Test("a cache hit never appears in an observable queue snapshot")
    func cachedURLNeverAppearsInQueueSnapshots() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let key = try SeparationCacheKey(url: files[0], modelSHA: Self.modelSHA)
        let cachedURL = files[0].deletingLastPathComponent().appendingPathComponent("cached.m4a")
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: FakeStemSeparator(latency: .milliseconds(15)),
            cache: FakeInstrumentalCache(seeded: [key: cachedURL]),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { !collector.finished.isEmpty }

        let empty = KaraokeQueueSnapshot(currentURL: nil, pendingURLs: [], isPaused: false)
        #expect(collector.finished == [FinishedEvent(url: files[0], result: .alreadyCached)])
        #expect(collector.snapshots == [empty])
    }

    @Test("a legacy identity-less cache entry self-heals on its first cache hit")
    func legacyIdentityLessEntrySelfHealsOnCacheHit() async throws {
        let files = try Self.makeTempFiles(count: 1)
        let identity = try SeparationCacheKey.sourceIdentity(for: files[0])
        let key = SeparationCacheKey(identity: identity, modelSHA: Self.modelSHA)
        let cacheDirectory = files[0].deletingLastPathComponent().appendingPathComponent("instrumentals")
        let cache = try InstrumentalCache(directory: cacheDirectory, modelSHA: Self.modelSHA)
        _ = try await cache.store(files[0], for: key, identity: nil)
        #expect(await cache.readySnapshot().records.isEmpty)

        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = KaraokeRenderResultCollector()
        let service = KaraokeRenderService(separator: separator, cache: cache, modelSHA: Self.modelSHA)
        service.onFinished = { collector.record(url: $0, result: $1) }

        service.setEnabled(true)
        service.requestRender(files[0])
        await Self.waitUntil { !collector.events.isEmpty }

        #expect(separator.separateCallCount == 0)
        #expect(collector.events == [KaraokeRenderResultEvent(url: files[0], result: .alreadyCached)])
        let snapshot = await cache.readySnapshot()
        #expect(snapshot.sequence == 2)
        #expect(snapshot.records == [Self.readyRecord(identity: identity, key: key)])
    }

    @Test("a missing source reports failed without invoking the separator")
    func missingSourceReportsFailed() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-karaoke-source-\(UUID().uuidString).flac")
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = KaraokeRenderResultCollector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(url: $0, result: $1) }

        service.setEnabled(true)
        service.requestRender(missingURL)
        await Self.waitUntil { !collector.events.isEmpty }

        #expect(separator.separateCallCount == 0)
        #expect(collector.events == [KaraokeRenderResultEvent(url: missingURL, result: .failed)])
    }

    private static func readyRecord(identity: SourceIdentity, key: SeparationCacheKey) -> ReadyRecord {
        ReadyRecord(
            sourcePath: identity.path,
            sourceFileSize: identity.fileSize,
            sourceMTime: identity.mtime,
            keyHex: key.hexValue
        )
    }
}

private struct KaraokeRenderResultEvent: Equatable {
    let url: URL
    let result: KaraokeRenderResult
}

private final class KaraokeRenderResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KaraokeRenderResultEvent] = []

    func record(url: URL, result: KaraokeRenderResult) {
        lock.withLock { storage.append(KaraokeRenderResultEvent(url: url, result: result)) }
    }

    var events: [KaraokeRenderResultEvent] {
        lock.withLock { storage }
    }
}
