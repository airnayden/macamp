//
//  CanonicalSampleLayout.swift
//  MacAMP PlayerCore — Services
//
//  Reduces one block of decoded PCM to FLAC's CANONICAL unencoded-sample bytes.
//
//  FLAC's STREAMINFO MD5 is taken over "the unencoded audio data": samples
//  INTERLEAVED frame-major / channel-minor, each written as `(bps + 7) / 8`
//  bytes of little-endian two's complement — libFLAC's `FLAC__MD5Accumulate`
//  with `bytes_per_sample = (bps + 7) / 8`. Reproducing that byte stream
//  exactly is the whole job of this type.
//
//  The bridge hands back what SFB's FLAC decoder produces: signed integers in
//  32-bit containers, DE-interleaved, and aligned HIGH — the decoder writes
//  `dst[i] = src[i] << (32 - bps)` (`SFBFLACDecoder.mm:575-599`). Undoing that
//  is one ARITHMETIC right shift per sample: linear, exact, sign-preserving,
//  and with no dither or rounding anywhere in the path. Going through float
//  (as ``PlanarSampleStream`` and `decodeAll` both do) would be wrong here —
//  the digest is defined over integers, and a normalise/denormalise round trip
//  is not guaranteed to be the identity.
//
//  PlayerCore portability: AVFAudio + Foundation.
//

import AVFAudio
import Foundation

/// Describes how to turn a decoder's PCM blocks into FLAC canonical bytes.
struct CanonicalSampleLayout {
    /// Channels in the stream, in the source's own order.
    let channelCount: Int

    /// The FLAC stream's bit depth (`STREAMINFO.bits_per_sample`).
    let bitsPerSample: Int

    /// Bytes each sample occupies in the digest stream: `(bps + 7) / 8`.
    let bytesPerSample: Int

    /// Arithmetic right shift that undoes the decoder's high alignment.
    let shift: Int32

    /// `true` when all channels share one buffer (SFB's FLAC decoder is
    /// de-interleaved, but the region wrapper is not contractually so).
    let isInterleaved: Bool

    /// Bytes one frame occupies in the digest stream.
    var frameByteCount: Int {
        channelCount * bytesPerSample
    }

    /// Derives the layout from a decoder's processing format.
    ///
    /// Returns `nil` for anything this verifier does not model — floating
    /// point, big-endian, a non-32-bit container, or an out-of-range depth —
    /// rather than guessing and producing a confidently wrong digest.
    init?(format: AVAudioFormat) {
        let asbd = format.streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let flags = asbd.mFormatFlags
        guard flags & kAudioFormatFlagIsFloat == 0,
              flags & kAudioFormatFlagIsBigEndian == 0,
              flags & kAudioFormatFlagIsSignedInteger != 0
        else {
            return nil
        }

        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }

        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let frameBytes = Int(asbd.mBytesPerFrame)
        let containerBytes = interleaved ? frameBytes / channels : frameBytes
        guard containerBytes == MemoryLayout<Int32>.size else { return nil }

        let bits = Int(asbd.mBitsPerChannel)
        guard bits > 0, bits <= containerBytes * 8 else { return nil }

        channelCount = channels
        bitsPerSample = bits
        bytesPerSample = (bits + 7) / 8
        isInterleaved = interleaved
        // Low-aligned containers (the bps == 32 case, which SFB memcpy's
        // through untouched) already hold the sample value.
        shift = flags & kAudioFormatFlagIsAlignedHigh != 0 ? Int32(containerBytes * 8 - bits) : 0
    }

    // MARK: Packing

    /// Writes `buffer`'s frames into `scratch` as canonical interleaved bytes.
    ///
    /// - Returns: Bytes written, or `nil` when the buffer's shape contradicts
    ///   the layout (a missing channel pointer, or a scratch buffer too small).
    ///   `nil` is a hard failure, never a short write — a partially filled
    ///   scratch would silently corrupt the digest.
    func pack(_ buffer: AVAudioPCMBuffer, into scratch: inout [UInt8]) -> Int? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let frameBytes = frameByteCount
        let produced = frames * frameBytes
        guard scratch.count >= produced else { return nil }

        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let bases = channelBases(in: list) else { return nil }

        scratch.withUnsafeMutableBufferPointer { out in
            for channel in 0 ..< channelCount {
                write(bases[channel], frames: frames, channel: channel, into: out)
            }
        }
        return produced
    }

    /// Distance between consecutive frames of one channel, in `Int32` units.
    private var sampleStride: Int {
        isInterleaved ? channelCount : 1
    }

    // MARK: Private

    /// Resolves one read pointer per channel, or `nil` if any is unavailable.
    private func channelBases(in list: UnsafeMutableAudioBufferListPointer) -> [UnsafePointer<Int32>]? {
        var bases: [UnsafePointer<Int32>] = []
        bases.reserveCapacity(channelCount)
        for channel in 0 ..< channelCount {
            let index = isInterleaved ? 0 : channel
            guard index < list.count, let raw = list[index].mData else { return nil }
            let typed = raw.assumingMemoryBound(to: Int32.self)
            bases.append(UnsafePointer(typed + (isInterleaved ? channel : 0)))
        }
        return bases
    }

    /// Scatters one channel's samples into their interleaved byte slots.
    ///
    /// Channel-major iteration with a strided write is deliberate: it keeps the
    /// per-sample shift out of the inner interleave and reads each source
    /// buffer contiguously.
    private func write(
        _ base: UnsafePointer<Int32>,
        frames: Int,
        channel: Int,
        into out: UnsafeMutableBufferPointer<UInt8>
    ) {
        let stride = sampleStride
        let frameBytes = frameByteCount
        var offset = channel * bytesPerSample
        for frame in 0 ..< frames {
            var value = base[frame * stride] >> shift
            for byte in 0 ..< bytesPerSample {
                out[offset + byte] = UInt8(truncatingIfNeeded: value)
                value >>= 8
            }
            offset += frameBytes
        }
    }
}
