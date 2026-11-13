// Resampler — offline normalisation of decoded PCM to the separation model's
// native input format: 44.1 kHz, 2-channel, deinterleaved float32.
//
// This is OFFLINE (pre-render) processing, NOT audio-thread code: it allocates
// freely and drives `AVAudioConverter` for sample-rate conversion. It mirrors the
// `AVAudioConverter` usage in `Decoding/PCMDecoding.swift` (FloatNormaliser —
// bit-depth/interleaving only), extended here to also resample. PlayerCore
// portability: imports only AVFAudio + Foundation (no AppKit/UIKit).
import AVFAudio
import Foundation

/// Converts any decoded PCM buffer to the Mel-Band Roformer model's native input
/// format: **44.1 kHz, 2 channels, deinterleaved float32**.
///
/// Behaviour:
/// - already 44.1 kHz stereo deinterleaved float32 ⇒ **pass-through** (the exact
///   same buffer is returned, with no conversion);
/// - mono ⇒ resampled to 44.1 kHz, then **duplicated** into two identical channels;
/// - more than two channels ⇒ throws ``SeparationError/unsupportedChannelLayout``.
public struct Resampler {
    /// The model-native sample rate.
    public static let targetSampleRate: Double = 44100
    /// The model-native channel count.
    public static let targetChannelCount: AVAudioChannelCount = 2

    public init() {}

    /// Normalises `buffer` to 44.1 kHz / 2ch / deinterleaved float32.
    ///
    /// - Throws: ``SeparationError/unsupportedChannelLayout`` when the input has
    ///   more than two channels; ``SeparationError/decodeFailed`` if the conversion
    ///   machinery cannot be constructed (unreachable for valid float PCM input).
    public func normalise(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        switch buffer.format.channelCount {
        case 1:
            let mono = try resample(buffer, channels: 1)
            return try duplicateMonoToStereo(mono)
        case 2:
            return try resample(buffer, channels: 2)
        default:
            throw SeparationError.unsupportedChannelLayout
        }
    }

    // MARK: - Sample-rate conversion

    /// Resamples `buffer` to 44.1 kHz at `channels`, preserving channel count.
    /// Returns the input untouched when it already matches the target format.
    private func resample(
        _ buffer: AVAudioPCMBuffer,
        channels: AVAudioChannelCount
    ) throws -> AVAudioPCMBuffer {
        let source = buffer.format
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw SeparationError.decodeFailed
        }
        if isTargetFormat(source, channels: channels) {
            return buffer
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw SeparationError.decodeFailed
        }
        return try convert(buffer, using: converter, to: target)
    }

    /// True when `format` is already 44.1 kHz / `channels` / deinterleaved float32.
    private func isTargetFormat(
        _ format: AVAudioFormat,
        channels: AVAudioChannelCount
    ) -> Bool {
        format.sampleRate == Self.targetSampleRate
            && format.channelCount == channels
            && format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved
    }

    /// Runs a full offline conversion of `input` through `converter`.
    ///
    /// Output capacity is generous (`inputFrames · ratio` plus slack for filter
    /// latency) so a single `convert(to:error:withInputFrom:)` call drains the
    /// finite input completely.
    private func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(capacity, 1)) else {
            throw SeparationError.decodeFailed
        }
        let feeder = SingleShotInput(input)
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            feeder.next(status)
        }
        guard result != .error, conversionError == nil, output.frameLength > 0 else {
            throw SeparationError.decodeFailed
        }
        return output
    }

    // MARK: - Channel duplication

    /// Duplicates a mono buffer's single channel into two identical channels,
    /// guaranteeing a deterministic L == R stereo result (no converter up-mix).
    private func duplicateMonoToStereo(_ mono: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: mono.format.sampleRate,
                channels: Self.targetChannelCount,
                interleaved: false
            ),
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(mono.frameCapacity, 1)),
            let source = mono.floatChannelData?[0],
            let destination = output.floatChannelData
        else {
            throw SeparationError.decodeFailed
        }
        let frames = Int(mono.frameLength)
        destination[0].update(from: source, count: frames)
        destination[1].update(from: source, count: frames)
        output.frameLength = mono.frameLength
        return output
    }
}

// MARK: - Converter input feeder

/// Feeds a finite buffer to `AVAudioConverter` once, then reports end-of-stream.
/// `@unchecked Sendable` is sound because the converter invokes the input block
/// synchronously on the calling thread — no real concurrency despite `@Sendable`.
private final class SingleShotInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Returns the buffer on the first call, then `nil` with `.endOfStream`.
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if consumed {
            status.pointee = .endOfStream
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
