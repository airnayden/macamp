// StemSeparating — the seam over "turn a song into an instrumental".
//
// The production conformer (todo 9, `SeparationPipeline`) decodes → resamples →
// STFT → Core ML → iSTFT → ALAC-encodes → caches; the `FakeStemSeparator` in
// PlayerCoreTestSupport is a deterministic, file-free double. `availability` is
// `async` because the real conformer wraps an `actor` (Core ML `MLModel` is
// non-Sendable and never crosses isolation), so reading its readiness hops actors.
// This file imports only Foundation and MUST NOT import AppKit/UIKit (PlayerCore
// portability invariant).
import Foundation

/// Separates a song into an instrumental (vocals removed) offline.
///
/// Conformers are `Sendable` so they can be shared across isolation domains (the
/// coordinator, the pre-warm service, background tasks). Separation is inherently
/// off-line and non-real-time — never call it on the audio thread.
public protocol StemSeparating: Sendable {
    /// Whether separation can run right now (model loaded + compatible).
    ///
    /// Callers MUST gate on this before ``separate(url:progress:)`` — an
    /// `.unavailable` separator throws ``SeparationError/modelUnavailable``.
    var availability: SeparationAvailability { get async }

    /// Renders the instrumental for the track at `url`, returning the URL of the
    /// written instrumental file.
    ///
    /// - Parameters:
    ///   - url: The original (mixed) source audio file.
    ///   - progress: Invoked with a `0...1` completion fraction as the pipeline
    ///     advances. It is `@Sendable` because stages may report from background
    ///     tasks; keep the closure cheap and non-blocking.
    /// - Returns: The URL of the rendered instrumental (typically a cached `.m4a`).
    /// - Throws: A ``SeparationError`` when any stage fails, or `CancellationError`
    ///   if the surrounding `Task` is cancelled.
    func separate(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

public extension StemSeparating {
    /// Convenience overload for callers that do not need progress updates.
    func separate(url: URL) async throws -> URL {
        try await separate(url: url, progress: { _ in })
    }
}
