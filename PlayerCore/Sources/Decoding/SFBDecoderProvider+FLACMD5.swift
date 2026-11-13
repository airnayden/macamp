//
//  SFBDecoderProvider+FLACMD5.swift
//  MacAMP PlayerCore — Decoding
//
//  Publishes the FLAC STREAMINFO MD5 through ``FLACStreamMD5Providing``.
//
//  SFB's FLAC decoder stores the STREAMINFO checksum under
//  `SFBAudioDecodingPropertiesKeyFLACMD5Sum` (raw value `"md5sum"`), populated
//  when the decoder is opened. `SFBDecoderAdapter` only ever holds an opened
//  backend, so the value is available for the adapter's whole lifetime.
//
//  Deliberately a SEPARATE file from `SFBDecoderProvider.swift`: this is an
//  additive seam, and keeping it out of the main bridge file leaves that file
//  free for codec-routing work.
//
//  PlayerCore portability: Foundation + SFBAudioEngine.
//

import Foundation
@preconcurrency import SFBAudioEngine

extension SFBDecoderAdapter: FLACStreamMD5Providing {
    /// The STREAMINFO MD5, or `nil` when the backend is not a FLAC decoder (or
    /// published a value of the wrong shape).
    ///
    /// Length is checked against ``FLACStreamMD5Providing/flacStreamMD5ByteCount``
    /// so a truncated or oversized blob can never reach a comparison that would
    /// then report a spurious mismatch.
    var flacStreamMD5: Data? {
        guard
            let value = sfbBackend.properties[Self.md5SumKey] as? Data,
            value.count == Self.flacStreamMD5ByteCount
        else {
            return nil
        }
        return value
    }

    /// `SFBAudioDecodingPropertiesKeyFLACMD5Sum` — referenced by its raw value
    /// because the Swift name Clang synthesises for that `NS_TYPED_ENUM`
    /// constant is an acronym-folding detail of the importer, whereas the
    /// dictionary key itself is the stable wire value SFB writes
    /// (`SFBFLACDecoder.mm:39`).
    private static var md5SumKey: AudioDecodingPropertiesKey {
        AudioDecodingPropertiesKey(rawValue: "md5sum")
    }
}
