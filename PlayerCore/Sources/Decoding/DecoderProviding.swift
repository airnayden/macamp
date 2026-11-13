// DecoderProviding — the Sendable factory abstraction for PCM decoders.
//
// A provider is the injectable seam between callers and a decoding backend:
// production code uses ``SFBDecoderProvider`` (real files through SFBAudioEngine)
// while tests use ``FakeDecoderProvider`` (synthesised PCM, no files). Providers
// are stateless value types and therefore `Sendable`; the *decoders* they vend
// are thread-confined and intentionally are not.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A `Sendable` factory that opens audio sources as ``PCMDecoding`` instances.
///
/// Conformers expose the set of containers/extensions and MIME types they can
/// open as **static** metadata (so callers can query support without first
/// constructing a provider), and a single throwing factory method that opens a
/// URL into a ready-to-pull PCM decoder.
public protocol DecoderProviding: Sendable {
    /// Opens `url` and returns a decoder positioned at the start of the stream.
    ///
    /// The returned decoder's ``PCMDecoding/processingFormat`` is valid
    /// immediately (the backend has already probed the header). DSD sources are
    /// transparently routed through a DSD→PCM stage so the output is always PCM.
    ///
    /// - Throws: ``DecodingError`` for unreadable, unsupported, corrupt or
    ///   truncated input. This method never traps and never throws a raw
    ///   backend error.
    func makeDecoder(for url: URL) throws -> any PCMDecoding

    /// Opens `source` and returns a decoder positioned at the start of the
    /// requested region.
    ///
    /// The object-returning counterpart of ``makeDecoder(for:)-(URL)`` for
    /// sources a URL cannot describe: when ``DecoderSource/frameRange`` is set
    /// the decoder emits ONLY that region, which is how one disc image exposes a
    /// CUE sheet's tracks as separate playable items.
    ///
    /// - Throws: ``DecodingError`` for unreadable, unsupported, corrupt or
    ///   truncated input — and for a ranged source the backend cannot honour.
    func makeDecoder(for source: DecoderSource) throws -> any PCMDecoding

    /// Lower-cased path extensions the backend can open (e.g. `flac`, `mp3`).
    static var supportedPathExtensions: Set<String> { get }

    /// MIME types the backend can open (e.g. `audio/flac`, `audio/mpeg`).
    static var supportedMIMETypes: Set<String> { get }
}

public extension DecoderProviding {
    /// Opens a whole-stream source through ``makeDecoder(for:)-(URL)``.
    ///
    /// A backend that cannot restrict decoding to a region rejects a ranged
    /// source instead of quietly playing the whole file — silently losing the
    /// range would make a CUE-sheet track play its entire disc image.
    func makeDecoder(for source: DecoderSource) throws -> any PCMDecoding {
        guard source.frameRange == nil else {
            throw DecodingError.unsupportedFormat(url: source.url)
        }
        return try makeDecoder(for: source.url)
    }

    /// Whether `url`'s path extension is one the backend advertises support for.
    ///
    /// A cheap pre-flight check (extension only) — it does not read the file, so
    /// a `true` result is necessary but not sufficient; ``makeDecoder(for:)``
    /// remains the source of truth and may still throw on bad content.
    func canOpen(url: URL) -> Bool {
        Self.supportedPathExtensions.contains(url.pathExtension.lowercased())
    }
}
