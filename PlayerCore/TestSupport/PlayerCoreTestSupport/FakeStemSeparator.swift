// FakeStemSeparator — a deterministic, file-free ``StemSeparating`` double.
//
// Mirrors the project's DI convention: every service ships a `Fake` so consumers and
// tests are written once against the abstraction. This double touches no Core ML, no
// audio files and no disk — it records the URLs it was asked to separate (in order),
// fires `progress(0)` then `progress(1)`, and returns a configured output URL (or
// echoes the input). An injectable `latency` lets concurrency tests (todo 13)
// observe scheduling: the double tracks its peak in-flight count so a test can assert
// the pre-warm service never runs more than one separation at a time.
//
// Style mirrors `FakeLyricsProvider`: a `@unchecked Sendable` final class guarded by
// an `NSLock` (the protocol is `Sendable`, not `@MainActor`).
import Foundation
import Separation

/// A canned ``StemSeparating`` for previews and higher-layer tests.
public final class FakeStemSeparator: StemSeparating, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredAvailability: SeparationAvailability
    private var configuredResult: URL?
    private var configuredError: SeparationError?
    private var perURLErrors: [URL: SeparationError] = [:]
    private var configuredLatency: Duration
    private var requested: [URL] = []
    private var inFlight = 0
    private var observedMaxConcurrency = 0

    /// - Parameters:
    ///   - availability: What ``availability`` reports (default `.available`).
    ///   - result: The URL ``separate(url:progress:)`` returns; `nil` echoes the input.
    ///   - error: When set, ``separate(url:progress:)`` throws it instead of returning.
    ///   - latency: An artificial delay before completing, so tests can overlap calls.
    public init(
        availability: SeparationAvailability = .available,
        returning result: URL? = nil,
        failingWith error: SeparationError? = nil,
        latency: Duration = .zero
    ) {
        configuredAvailability = availability
        configuredResult = result
        configuredError = error
        configuredLatency = latency
    }

    public var availability: SeparationAvailability {
        get async { lock.withLock { configuredAvailability } }
    }

    public func separate(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock {
            requested.append(url)
            inFlight += 1
            observedMaxConcurrency = max(observedMaxConcurrency, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }

        progress(0)
        let latency = lock.withLock { configuredLatency }
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        if let error = lock.withLock({ perURLErrors[url] ?? configuredError }) {
            throw error
        }
        guard lock.withLock({ configuredAvailability.isAvailable }) else {
            throw SeparationError.modelUnavailable
        }
        progress(1)
        return lock.withLock { configuredResult } ?? url
    }
}

// MARK: - Inspection + configuration

public extension FakeStemSeparator {
    /// Every URL this double was asked to separate, in call order.
    var requestedURLs: [URL] {
        lock.withLock { requested }
    }

    /// The number of ``separate(url:progress:)`` calls received.
    var separateCallCount: Int {
        lock.withLock { requested.count }
    }

    /// The peak number of overlapping ``separate(url:progress:)`` calls observed.
    var maxObservedConcurrency: Int {
        lock.withLock { observedMaxConcurrency }
    }

    func setAvailability(_ availability: SeparationAvailability) {
        lock.withLock { configuredAvailability = availability }
    }

    func setResult(_ result: URL?) {
        lock.withLock { configuredResult = result }
    }

    func setError(_ error: SeparationError?) {
        lock.withLock { configuredError = error }
    }

    /// Fails only `url` with `error` (or clears it when `nil`); every other URL still succeeds.
    func setError(_ error: SeparationError?, for url: URL) {
        lock.withLock { perURLErrors[url] = error }
    }

    func setLatency(_ latency: Duration) {
        lock.withLock { configuredLatency = latency }
    }
}
