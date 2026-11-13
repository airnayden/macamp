// DecoderSource — what to decode, expressed as a value.
//
// A URL alone cannot describe every playable item. A CUE-sheet track is a frame
// RANGE inside one large disc image, and a DSD source has to reach the player as
// an already-opened decoder OBJECT rather than a URL the player re-opens through
// its own (PCM-only) factory. `DecoderSource` is the value both cases share — a
// URL plus an optional frame range — and ``DecoderProviding/makeDecoder(for:)``
// is the single place it becomes a concrete ``PCMDecoding``.
//
// NAME: deliberately NOT `PlaybackSource` — `Services` already ships a public
// `PlaybackSource` enum (which browsing surface a queue came from, persisted in
// `profilePlaybackState`). The two collide in every module that imports both.
//
// This file imports only AVFAudio + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

/// A playable item: a source URL and, optionally, the region within it to play.
///
/// `DecoderSource(url:)` is exactly equivalent to the URL-only load path, so
/// every existing caller keeps its behaviour; the frame range is what lets one
/// file expose many playable items (a CUE sheet's tracks inside a disc image).
public struct DecoderSource: Sendable, Equatable, Hashable {
    /// The file to decode.
    public let url: URL

    /// The half-open frame region to play, or `nil` for the whole stream.
    ///
    /// Frames are counted in the decoder's `processingFormat` from the start of
    /// the stream. Backends that cannot restrict decoding to a region reject a
    /// ranged source with a typed ``DecodingError`` rather than silently playing
    /// the whole file.
    public let frameRange: Range<AVAudioFramePosition>?

    public init(url: URL, frameRange: Range<AVAudioFramePosition>? = nil) {
        self.url = url
        self.frameRange = frameRange
    }
}
