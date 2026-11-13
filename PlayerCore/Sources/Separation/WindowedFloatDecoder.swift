// WindowedFloatDecoder — streams an entire source stream to a deinterleaved
// float32 buffer using bounded, windowed `decode(into:)` pulls.
//
// This is DELIBERATELY NOT `PCMDecoding.decodeAll()`: the separation pipeline drives
// the decode itself so it controls the block size and so the memory-dominant STFT /
// inference stage downstream can process the signal in bounded windows rather than
// materialising a full-track spectrogram. Each decoded block is normalised to
// deinterleaved float32 (a passthrough when the decoder already emits that) so the
// pipeline's resample + STFT stages always see real samples regardless of the
// source codec's native bit depth. Any decode failure surfaces as
// ``SeparationError/decodeFailed``.
//
// OFFLINE (pre-render) processing, NOT audio-thread code: it allocates freely and
// drives `AVAudioConverter`. PlayerCore portability: imports only AVFAudio +
// Foundation + the Decoding module (no AppKit/UIKit).
import AVFAudio
import Decoding
import Foundation

/// Decodes a whole source stream to deinterleaved float32 (at the source sample
/// rate) via windowed ``PCMDecoding/decode(into:frameLength:)`` pulls.
struct WindowedFloatDecoder {
    /// Frames pulled from the decoder per iteration (the decode window size).
    let blockSize: AVAudioFrameCount

    /// Fully decodes `decoder` into one deinterleaved float32 buffer at the source
    /// sample rate. The result feeds ``Resampler/normalise(_:)`` (which handles the
    /// rate / channel-count conversion to the model-native format).
    ///
    /// - Throws: ``SeparationError/decodeFailed`` for any allocation, conversion or
    ///   backend decode failure.
    func decode(_ decoder: any PCMDecoding) throws -> AVAudioPCMBuffer {
        let sourceFormat = decoder.processingFormat
        let sampleRate = sourceFormat.sampleRate > 0 ? sourceFormat.sampleRate : Resampler.targetSampleRate
        let channelCount = AVAudioChannelCount(max(sourceFormat.channelCount, 1))
        guard
            let floatFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount),
            let scratch = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: max(blockSize, 1))
        else {
            throw SeparationError.decodeFailed
        }
        let converter = try makeConverter(from: sourceFormat, to: floatFormat)
        var channels = [[Float]](repeating: [], count: Int(channelCount))
        while true {
            try Task.checkCancellation()
            let produced = try pull(decoder, into: scratch)
            if produced == 0 { break }
            let block = try normalise(scratch, converter: converter, format: floatFormat)
            append(block, into: &channels)
        }
        return try assemble(channels, sampleRate: sampleRate)
    }

    // MARK: - Stages

    /// Builds the source→float converter, or `nil` when the source is already the
    /// deinterleaved float target (a passthrough — no per-block conversion needed).
    private func makeConverter(from source: AVAudioFormat, to target: AVAudioFormat) throws -> AVAudioConverter? {
        if source == target { return nil }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw SeparationError.decodeFailed
        }
        return converter
    }

    /// Pulls one block into `scratch`, mapping any backend decode failure to the
    /// typed ``SeparationError/decodeFailed``.
    private func pull(_ decoder: any PCMDecoding, into scratch: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        do {
            return try decoder.decode(into: scratch, frameLength: scratch.frameCapacity)
        } catch {
            throw SeparationError.decodeFailed
        }
    }

    /// Returns `scratch` unchanged for a float passthrough, otherwise converts it to
    /// deinterleaved float32 (same sample rate ⇒ the one-shot form is sufficient).
    private func normalise(
        _ scratch: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter else { return scratch }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: scratch.frameCapacity) else {
            throw SeparationError.decodeFailed
        }
        do {
            try converter.convert(to: output, from: scratch)
        } catch {
            throw SeparationError.decodeFailed
        }
        return output
    }

    /// Appends the produced frames of every channel of `buffer` onto `channels`.
    private func append(_ buffer: AVAudioPCMBuffer, into channels: inout [[Float]]) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0 ..< channels.count {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames))
        }
    }

    /// Packs the accumulated per-channel samples into one deinterleaved float buffer.
    private func assemble(_ channels: [[Float]], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let channelCount = AVAudioChannelCount(max(channels.count, 1))
        let frames = AVAudioFrameCount(channels.first?.count ?? 0)
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)),
            let data = buffer.floatChannelData
        else {
            throw SeparationError.decodeFailed
        }
        buffer.frameLength = frames
        for channel in 0 ..< Int(channelCount) where channel < channels.count {
            channels[channel].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                data[channel].update(from: base, count: Int(frames))
            }
        }
        return buffer
    }
}
