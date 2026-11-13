//
//  FLACFixtureWriter.swift
//  MacAMP PlayerCore — IntegrityTests
//
//  Encodes known-good FLAC files IN-TEST via SFBAudioEngine's own FLAC encoder.
//
//  This makes libFLAC the oracle. `FLAC__stream_encoder_finish` rewrites
//  STREAMINFO with libFLAC's MD5 of the samples it was handed, so a `.match`
//  verdict is a statement that MacAMP's canonical-sample reconstruction agrees
//  with libFLAC's, sample for sample — which a committed binary could never
//  prove on its own. No external tool is invoked at any point.
//

import AVFAudio
import Foundation
import SFBAudioEngine

/// A deterministic PCM signal and the FLAC stream parameters to encode it with.
struct FLACFixtureSpec {
    var sampleRate: Double = 44100
    var channelCount: Int = 2
    var bitsPerSample: Int = 16
    var frameCount: Int = 16384

    /// Distinguishes two otherwise identical fixtures, so a test can produce
    /// streams whose audio — and therefore whose MD5 — genuinely differ.
    var seed: Int = 1

    /// Largest magnitude a sample of this depth may take without clipping.
    var fullScale: Double {
        Double((1 << (bitsPerSample - 1)) - 1)
    }
}

enum FLACFixtureError: Error {
    case unconstructibleFormat
    case unallocatableBuffer
    case missingBufferData
}

enum FLACFixtureWriter {
    /// Writes `spec`'s signal to `url` as a native FLAC stream.
    @discardableResult
    static func write(_ spec: FLACFixtureSpec, to url: URL) throws -> [[Int32]] {
        let planar = samples(spec)
        // Selected by the `.flac` path extension rather than by
        // `SFBAudioEncoderNameFLAC`: that `NS_TYPED_ENUM` constant does not
        // import as a member of `AudioEncoder.Name`, and spelling its reverse-DNS
        // raw value here would hardcode an SFB implementation detail.
        let encoder = try AudioEncoder(url: url)
        try encoder.setSourceFormat(sourceFormat(spec))
        encoder.estimatedFramesToEncode = AVAudioFramePosition(spec.frameCount)
        // `openReturningError()`, not `open()`: `SFBAudioEncoding` omits the
        // `NS_SWIFT_NAME(open())` that `SFBAudioDecoding` carries.
        try encoder.openReturningError()

        let buffer = try makeBuffer(format: encoder.processingFormat, spec: spec, planar: planar)
        try encoder.encode(from: buffer, length: AVAudioFrameCount(spec.frameCount))
        try encoder.finish()
        try encoder.close()
        return planar
    }

    /// The fixture signal: a per-channel sine whose frequency and phase are
    /// derived from the seed, quantised to the target depth.
    ///
    /// Integers are generated directly rather than rounded from a float buffer
    /// so the bytes handed to libFLAC are exactly the bytes the test intends —
    /// no conversion sits between the signal and the oracle.
    static func samples(_ spec: FLACFixtureSpec) -> [[Int32]] {
        let amplitude = spec.fullScale * 0.82
        return (0 ..< spec.channelCount).map { channel in
            let frequency = 220.0 * Double(spec.seed) + 97.0 * Double(channel)
            let phase = Double(channel) * 0.37 + Double(spec.seed) * 0.11
            let step = 2.0 * Double.pi * frequency / spec.sampleRate
            return (0 ..< spec.frameCount).map { frame in
                Int32((amplitude * sin(step * Double(frame) + phase)).rounded())
            }
        }
    }

    // MARK: Private

    /// A packed signed-integer source format at the fixture's own bit depth —
    /// the encoder derives its FLAC `bits_per_sample` from `mBitsPerChannel`.
    private static func sourceFormat(_ spec: FLACFixtureSpec) throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger
            | kAudioFormatFlagsNativeEndian
            | kAudioFormatFlagIsPacked
        asbd.mSampleRate = spec.sampleRate
        asbd.mChannelsPerFrame = UInt32(spec.channelCount)
        asbd.mBitsPerChannel = UInt32(spec.bitsPerSample)
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = UInt32(spec.channelCount * ((spec.bitsPerSample + 7) / 8))
        asbd.mBytesPerFrame = asbd.mBytesPerPacket
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw FLACFixtureError.unconstructibleFormat
        }
        return format
    }

    /// Fills the encoder's processing buffer: interleaved 32-bit containers
    /// with each sample aligned HIGH, which is what `SFBFLACEncoder` shifts
    /// back down before handing the block to libFLAC.
    private static func makeBuffer(
        format: AVAudioFormat,
        spec: FLACFixtureSpec,
        planar: [[Int32]]
    ) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(spec.frameCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw FLACFixtureError.unallocatableBuffer
        }
        buffer.frameLength = frames

        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let raw = list.first?.mData else { throw FLACFixtureError.missingBufferData }
        let destination = raw.assumingMemoryBound(to: Int32.self)

        let shift = Int32(32 - Int(format.streamDescription.pointee.mBitsPerChannel))
        for frame in 0 ..< spec.frameCount {
            for channel in 0 ..< spec.channelCount {
                destination[frame * spec.channelCount + channel] = planar[channel][frame] << shift
            }
        }
        return buffer
    }
}
