//
//  FLACStreamInfo.swift
//  MacAMP PlayerCore — IntegrityTests
//
//  Reads and patches the STREAMINFO checksum of an on-disk FLAC file.
//
//  Used to manufacture the two negative cases from a known-good encode: a
//  byte-flipped checksum (mismatch) and a zeroed one (no stored MD5). Patching
//  the METADATA field rather than the audio payload is what makes both cases
//  DETERMINISTIC — a flipped byte inside a FLAC frame invalidates that frame's
//  CRC, and whether the decoder then errors, resyncs, or silently skips is a
//  libFLAC implementation detail, not a property this verifier defines.
//

import Foundation

enum FLACStreamInfo {
    /// Byte range of STREAMINFO's MD5 field in a native FLAC stream.
    ///
    ///     "fLaC"                     4 bytes   → 0 ..< 4
    ///     METADATA_BLOCK_HEADER      4 bytes   → 4 ..< 8
    ///     STREAMINFO                34 bytes   → 8 ..< 42
    ///       min/max block size       4 bytes
    ///       min/max frame size       6 bytes
    ///       rate|channels|bps|total  8 bytes
    ///       md5                     16 bytes   → 26 ..< 42
    ///
    /// STREAMINFO is mandated to be the FIRST metadata block, so the offset is
    /// fixed for every conformant stream.
    static let md5Range = 26 ..< 42

    static let magic = Data("fLaC".utf8)

    enum PatchError: Error {
        case notAFLACStream
        case truncated
    }

    static func storedMD5(of url: URL) throws -> Data {
        let bytes = try validated(url)
        return bytes.subdata(in: md5Range)
    }

    /// Writes `url`'s bytes to `destination` with the checksum field replaced.
    static func copy(_ url: URL, to destination: URL, replacingMD5 replacement: Data) throws {
        var bytes = try validated(url)
        bytes.replaceSubrange(md5Range, with: replacement)
        try bytes.write(to: destination)
    }

    /// Writes a copy whose checksum differs from the original in exactly one bit.
    static func copy(_ url: URL, to destination: URL, flippingMD5ByteAt index: Int) throws {
        var checksum = try storedMD5(of: url)
        checksum[index] ^= 0x01
        try copy(url, to: destination, replacingMD5: checksum)
    }

    // MARK: Private

    private static func validated(_ url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        guard bytes.count >= md5Range.upperBound else { throw PatchError.truncated }
        guard bytes.prefix(magic.count) == magic else { throw PatchError.notAFLACStream }
        return bytes
    }
}
