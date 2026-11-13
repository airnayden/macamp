// The protocol seam for the library importer + its test double.
//
// Mirrors the project's DI convention (Decoding/Metadata/AudioEngine): every
// service exposes a protocol and ships a `Fake` so consumers and tests are
// written once against the abstraction.
import Foundation

// MARK: - LibraryScanning

/// Imports audio files into the library, reporting progress.
public protocol LibraryScanning: Sendable {
    /// Streams `.progress` events then a closing `.finished(summary)`.
    ///
    /// The scan is tied to the stream's lifetime: dropping the stream (or
    /// breaking the consuming `for await`) cancels the underlying scan at the
    /// next chunk boundary, leaving every already-committed chunk persisted.
    func events(for request: ScanRequest) -> AsyncStream<ScanEvent>

    /// Convenience: runs to completion and returns the final summary.
    func scan(_ request: ScanRequest) async -> ScanSummary
}

// MARK: - FakeLibraryScanner

/// A deterministic ``LibraryScanning`` double: emits one `.progress` per canned
/// candidate then a fixed `.finished` summary, touching no database/filesystem.
public struct FakeLibraryScanner: LibraryScanning {
    /// The summary every scan reports.
    public var summary: ScanSummary
    /// Number of `.progress` events to emit (0 ⇒ derive from the request).
    public var progressCount: Int

    public init(summary: ScanSummary = ScanSummary(), progressCount: Int = 0) {
        self.summary = summary
        self.progressCount = progressCount
    }

    public func events(for request: ScanRequest) -> AsyncStream<ScanEvent> {
        let summary = summary
        let total = resolvedTotal(for: request)
        return AsyncStream { continuation in
            for index in 0 ..< total {
                continuation.yield(.progress(ScanProgress(processed: index + 1, total: total)))
            }
            continuation.yield(.finished(summary))
            continuation.finish()
        }
    }

    public func scan(_: ScanRequest) async -> ScanSummary {
        summary
    }

    /// Prefers an explicit ``progressCount``, else the request's candidate count.
    private func resolvedTotal(for request: ScanRequest) -> Int {
        if progressCount > 0 {
            return progressCount
        }
        switch request {
        case let .files(urls):
            return urls.count
        case let .manifest(candidates):
            return candidates.count
        case .directory:
            return 0
        }
    }
}
