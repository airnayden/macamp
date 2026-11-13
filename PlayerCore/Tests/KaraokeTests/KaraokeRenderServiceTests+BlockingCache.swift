import Foundation
import PlayerCoreTestSupport
import Separation

/// An ``InstrumentalCaching`` decorator that suspends a chosen lookup until `release()`,
/// so a test can hold a render mid-flight and observe queue state deterministically.
/// Extracted from `KaraokeRenderServiceTests+StartNow.swift` to keep that file within the
/// SwiftLint file-length budget; `internal` (not `private`) so it stays reachable there.
actor BlockingLookupCache: InstrumentalCaching {
    private let base = FakeInstrumentalCache()
    private let blockedKey: SeparationCacheKey
    private let blockedLookupNumber: Int
    private var lookupCount = 0
    private var isReleased = false

    init(blockedKey: SeparationCacheKey, blockedLookupNumber: Int = 1) {
        self.blockedKey = blockedKey
        self.blockedLookupNumber = blockedLookupNumber
    }

    var isBlocked: Bool {
        lookupCount >= blockedLookupNumber && !isReleased
    }

    func release() {
        isReleased = true
    }

    func cachedInstrumental(for key: SeparationCacheKey) async -> URL? {
        guard key == blockedKey else { return await base.cachedInstrumental(for: key) }
        lookupCount += 1
        guard lookupCount == blockedLookupNumber else { return await base.cachedInstrumental(for: key) }
        while !isReleased {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return nil
            }
        }
        return await base.cachedInstrumental(for: key)
    }

    func store(_ source: URL, for key: SeparationCacheKey, identity: SourceIdentity?) async throws -> URL {
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

    func setOnEntriesChanged(_ handler: (@Sendable (Int, [ReadyRecord]) -> Void)?) async {
        await base.setOnEntriesChanged(handler)
    }

    func setMaxByteSize(_ newValue: Int64) async {
        await base.setMaxByteSize(newValue)
    }

    func relocate(to newDirectory: URL) async throws -> Bool {
        try await base.relocate(to: newDirectory)
    }
}
