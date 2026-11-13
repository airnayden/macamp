//
//  FLACStreamMD5.swift
//  MacAMP PlayerCore — Decoding
//
//  The one decoder-specific stream property the bridge publishes.
//
//  The Decoding module deliberately hides SFBAudioEngine's open-ended
//  `properties` dictionary: a caller that reached into it would be coupled to
//  the backend, and every key it could reach is either already modelled on
//  ``PCMDecoding`` (rate, channels, bit depth, length) or is codec trivia.
//
//  The FLAC STREAMINFO MD5 is the exception. It is the only stored value that
//  lets a caller PROVE a file still decodes to the samples it was encoded from,
//  and there is no other route to it — so it gets a narrow, named seam rather
//  than a generic property escape hatch.
//
//  PlayerCore portability: Foundation only.
//

import Foundation

/// A decoder that can publish the MD5 checksum stored in a FLAC stream's
/// STREAMINFO metadata block.
///
/// Cast an opened ``PCMDecoding`` to this protocol to read it:
///
/// ```swift
/// let decoder = try provider.makeDecoder(for: url)
/// let stored = (decoder as? any FLACStreamMD5Providing)?.flacStreamMD5
/// ```
///
/// A non-FLAC decoder simply does not conform, so a failed cast is the answer
/// for "this file has no FLAC stream MD5" rather than an error.
public protocol FLACStreamMD5Providing {
    /// The 16-byte MD5 the encoder recorded in STREAMINFO, or `nil` when the
    /// backend published no well-formed value.
    ///
    /// The bytes are returned **verbatim**. An all-zero checksum is a legal
    /// stored value whose defined meaning is "no MD5 was recorded", but that
    /// interpretation belongs to the caller — this property never substitutes
    /// `nil` for it, so a caller can distinguish "absent" from "explicitly
    /// blank".
    var flacStreamMD5: Data? { get }
}

public extension FLACStreamMD5Providing {
    /// Number of bytes in a FLAC STREAMINFO MD5 checksum.
    static var flacStreamMD5ByteCount: Int {
        16
    }
}
