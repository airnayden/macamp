// FakeAudioFeatureExtractor — a deterministic, file-free ``AudioFeatureExtracting`` double.
//
// Mirrors the project's DI convention: every service ships a `Fake` so consumers
// and tests are written once against the abstraction. This double decodes
// nothing and touches no disk — it records the URLs it was asked about (in
// order) and returns configured features, optionally after an injectable latency
// so todo 11's library-wide pass can observe scheduling, pause and cancellation.
//
// Style mirrors `FakeStemSeparator`: a `@unchecked Sendable` final class guarded
// by an `NSLock` (the protocol is `Sendable`, not `@MainActor`).
import Foundation
import Services

/// A canned ``AudioFeatureExtracting`` for previews and higher-layer tests.
public final class FakeAudioFeatureExtractor: AudioFeatureExtracting, @unchecked Sendable {
    /// The features returned when nothing more specific is configured.
    public static let defaultResult = AudioFeatureResult(bpm: 120, energy: 0.5, brightness: 0.5)

    private let lock = NSLock()
    private var configuredResult: AudioFeatureResult
    private var perURLResults: [URL: AudioFeatureResult] = [:]
    private var configuredError: AudioFeatureError?
    private var perURLErrors: [URL: AudioFeatureError] = [:]
    private var configuredLatency: Duration
    private var requested: [URL] = []

    /// - Parameters:
    ///   - result: What ``extractFeatures(from:)`` returns for any URL with no
    ///     per-URL override.
    ///   - error: When set, ``extractFeatures(from:)`` throws it instead.
    ///   - latency: An artificial delay before completing, so tests can cancel or
    ///     pause a pass while an extraction is in flight.
    public init(
        returning result: AudioFeatureResult = FakeAudioFeatureExtractor.defaultResult,
        failingWith error: AudioFeatureError? = nil,
        latency: Duration = .zero
    ) {
        configuredResult = result
        configuredError = error
        configuredLatency = latency
    }

    public func extractFeatures(from url: URL) async throws -> AudioFeatureResult {
        lock.withLock { requested.append(url) }
        let latency = lock.withLock { configuredLatency }
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        try Task.checkCancellation()
        if let error = lock.withLock({ perURLErrors[url] ?? configuredError }) {
            throw error
        }
        return lock.withLock { perURLResults[url] ?? configuredResult }
    }
}

// MARK: - Inspection + configuration

public extension FakeAudioFeatureExtractor {
    /// Every URL this double was asked to analyze, in call order.
    var requestedURLs: [URL] {
        lock.withLock { requested }
    }

    /// The number of ``extractFeatures(from:)`` calls received.
    var extractCallCount: Int {
        lock.withLock { requested.count }
    }

    func setResult(_ result: AudioFeatureResult) {
        lock.withLock { configuredResult = result }
    }

    /// Returns `result` only for `url`; every other URL keeps the default.
    func setResult(_ result: AudioFeatureResult?, for url: URL) {
        lock.withLock { perURLResults[url] = result }
    }

    func setError(_ error: AudioFeatureError?) {
        lock.withLock { configuredError = error }
    }

    /// Fails only `url` with `error` (or clears it when `nil`); every other URL still succeeds.
    func setError(_ error: AudioFeatureError?, for url: URL) {
        lock.withLock { perURLErrors[url] = error }
    }

    func setLatency(_ latency: Duration) {
        lock.withLock { configuredLatency = latency }
    }
}
