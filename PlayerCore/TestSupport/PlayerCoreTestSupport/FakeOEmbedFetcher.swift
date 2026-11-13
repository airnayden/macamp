// FakeOEmbedFetcher — a deterministic, network-free ``OEmbedFetching`` double.
//
// Mirrors the project's DI convention: every seam ships a `Fake` so consumers are
// written once against the abstraction. This double touches no `URLSession` and no
// disk — it answers from a canned table keyed by video id (and by URL for
// thumbnails), records what it was asked for in call order, and returns `nil` for
// anything it was not told about, which is exactly what the production conformer
// does for a 404 / 401 / timeout / malformed answer.
//
// An injectable `latency` lets a concurrency test overlap calls: the double tracks
// its peak in-flight count across BOTH methods, so a test can assert that a
// ``OEmbedConcurrencyGate`` really admits at most four lookups at a time.
//
// Style mirrors `FakeStemSeparator`: a `@unchecked Sendable` final class guarded by
// an `NSLock` (the protocol is `Sendable`, not `@MainActor`).
import Foundation
import Services

/// A canned ``OEmbedFetching`` for previews and higher-layer tests.
public final class FakeOEmbedFetcher: OEmbedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [String: OEmbedPayload]
    private var thumbnails: [URL: Data]
    private var configuredLatency: Duration
    private var requestedIDs: [String] = []
    private var requestedThumbnails: [URL] = []
    private var inFlight = 0
    private var observedMaxConcurrency = 0

    /// - Parameters:
    ///   - payloads: What ``fetch(videoID:)`` answers, keyed by video id. An id
    ///     that is absent answers `nil` — the "lookup produced nothing" outcome.
    ///   - thumbnails: What ``fetchThumbnail(url:)`` answers, keyed by URL.
    ///   - latency: An artificial delay before answering, so tests can overlap
    ///     calls and observe the concurrency window.
    public init(
        payloads: [String: OEmbedPayload] = [:],
        thumbnails: [URL: Data] = [:],
        latency: Duration = .zero
    ) {
        self.payloads = payloads
        self.thumbnails = thumbnails
        configuredLatency = latency
    }

    // MARK: - OEmbedFetching

    public func fetch(videoID: String) async -> OEmbedPayload? {
        lock.withLock { requestedIDs.append(videoID) }
        await withTrackedFlight()
        return lock.withLock { payloads[videoID] }
    }

    public func fetchThumbnail(url: URL) async -> Data? {
        lock.withLock { requestedThumbnails.append(url) }
        await withTrackedFlight()
        return lock.withLock { thumbnails[url] }
    }

    /// Counts one overlapping call and burns the configured latency inside it.
    ///
    /// Shared by both methods on purpose: the production window bounds LOOKUPS, not
    /// lookups-of-one-kind, so a metadata call and a thumbnail call must both
    /// occupy the same peak.
    private func withTrackedFlight() async {
        let latency = lock.withLock {
            inFlight += 1
            observedMaxConcurrency = max(observedMaxConcurrency, inFlight)
            return configuredLatency
        }
        defer { lock.withLock { inFlight -= 1 } }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
    }
}

// MARK: - Inspection + configuration

public extension FakeOEmbedFetcher {
    /// Every video id this double was asked about, in call order.
    var requestedVideoIDs: [String] {
        lock.withLock { requestedIDs }
    }

    /// Every thumbnail URL this double was asked for, in call order.
    var requestedThumbnailURLs: [URL] {
        lock.withLock { requestedThumbnails }
    }

    var fetchCallCount: Int {
        lock.withLock { requestedIDs.count }
    }

    var fetchThumbnailCallCount: Int {
        lock.withLock { requestedThumbnails.count }
    }

    /// The peak number of overlapping calls observed, across both methods.
    var maxObservedConcurrency: Int {
        lock.withLock { observedMaxConcurrency }
    }

    /// Arms (or clears, with `nil`) the answer for one video id, mid-test.
    func setPayload(_ payload: OEmbedPayload?, for videoID: String) {
        lock.withLock { payloads[videoID] = payload }
    }

    /// Arms (or clears, with `nil`) the bytes for one thumbnail URL, mid-test.
    func setThumbnail(_ data: Data?, for url: URL) {
        lock.withLock { thumbnails[url] = data }
    }

    func setLatency(_ latency: Duration) {
        lock.withLock { configuredLatency = latency }
    }
}
