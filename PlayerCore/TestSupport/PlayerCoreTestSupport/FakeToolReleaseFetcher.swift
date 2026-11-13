// FakeToolReleaseFetcher — a deterministic, network-free ``ToolReleaseFetching`` double.
//
// Serves a configured release and a configured URL→bytes map, so the tool manager's
// update logic — tag comparison, checksum verification, atomic install, rollback — is
// testable with zero `URLSession`. Every fetched URL is recorded so a test can assert
// the manager fetched the checksum manifest before trusting the asset.
//
// Style mirrors `FakeStemSeparator`: a `@unchecked Sendable` final class guarded by an
// `NSLock` (the protocol is `Sendable`, not `@MainActor`).
import Foundation
import Services

/// A canned ``ToolReleaseFetching`` for hermetic tests and previews.
public final class FakeToolReleaseFetcher: ToolReleaseFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredRelease: ToolRelease
    private var configuredPayloads: [URL: Data]
    private var configuredReleaseError: (any Error)?
    private var configuredFetchError: (any Error)?
    private var recordedURLs: [URL] = []
    private var releaseCalls = 0

    /// A stand-in release pointing at obviously-fake hosts, so a leaked real fetch is
    /// unmistakable in a failure message.
    public static let sampleRelease = ToolRelease(
        tag: "2025.02.02",
        assetURL: sampleURL(path: "yt-dlp_macos"),
        checksumURL: sampleURL(path: "SHA2-256SUMS")
    )

    /// Builds a `.invalid`-host URL. The string is a compile-time constant, so a parse
    /// failure is a genuine invariant violation, not a runtime condition to handle.
    private static func sampleURL(path: String) -> URL {
        guard let url = URL(string: "https://fake.invalid/\(path)") else {
            fatalError("FakeToolReleaseFetcher sample URL must parse: \(path)")
        }
        return url
    }

    /// - Parameters:
    ///   - release: What ``fetchLatestRelease()`` reports.
    ///   - payloads: Bytes served per URL. A URL absent from the map fails with
    ///     ``FakeToolReleaseFetcher/Failure/payloadMissing``.
    ///   - releaseError: When set, ``fetchLatestRelease()`` throws it.
    ///   - fetchError: When set, ``fetchData(from:)`` throws it for every URL.
    public init(
        release: ToolRelease = FakeToolReleaseFetcher.sampleRelease,
        payloads: [URL: Data] = [:],
        releaseError: (any Error)? = nil,
        fetchError: (any Error)? = nil
    ) {
        configuredRelease = release
        configuredPayloads = payloads
        configuredReleaseError = releaseError
        configuredFetchError = fetchError
    }

    /// The double's own failure vocabulary — never surfaced to a person, so it carries
    /// no `LocalizedStringResource`.
    public enum Failure: Error, Sendable, Equatable {
        /// No payload was configured for the requested URL.
        case payloadMissing(URL)
    }

    // MARK: - ToolReleaseFetching

    public func fetchLatestRelease() async throws -> ToolRelease {
        try lock.withLock {
            releaseCalls += 1
            if let error = configuredReleaseError { throw error }
            return configuredRelease
        }
    }

    public func fetchData(from url: URL) async throws -> Data {
        try lock.withLock {
            recordedURLs.append(url)
            if let error = configuredFetchError { throw error }
            guard let data = configuredPayloads[url] else { throw Failure.payloadMissing(url) }
            return data
        }
    }

    // MARK: - Test helpers

    /// Every URL passed to ``fetchData(from:)``, in order.
    public var fetchedURLs: [URL] {
        lock.withLock { recordedURLs }
    }

    /// How many times the release feed was queried.
    public var fetchLatestReleaseCallCount: Int {
        lock.withLock { releaseCalls }
    }

    /// Serves `data` for `url` on subsequent fetches.
    public func setPayload(_ data: Data, for url: URL) {
        lock.withLock { configuredPayloads[url] = data }
    }

    /// Repoints what ``fetchLatestRelease()`` reports, mid-test.
    public func setRelease(_ release: ToolRelease) {
        lock.withLock { configuredRelease = release }
    }
}
