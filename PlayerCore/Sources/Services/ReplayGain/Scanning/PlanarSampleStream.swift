//
//  PlanarSampleStream.swift
//  MacAMP PlayerCore — Services
//
//  Bounded windowed pulls from a decoder, as DE-INTERLEAVED float channels.
//
//    decoder.decode(into:frameLength:)  →  float32 normalisation  →  planar
//    channel pointers handed to the caller for the duration of one callback
//
//  The whole track is NEVER materialised — only `capacity` frames exist at once,
//  so a 74-minute stereo album file costs ~64 KB of PCM instead of ~1.5 GB. This
//  is deliberately NOT `PCMDecoding.decodeAll()` and NOT
//  `Separation.WindowedFloatDecoder`: both concatenate every block into one
//  whole-track buffer, which is precisely what a library-wide scan must not do.
//
//  It is also NOT ``MonoSampleStream``, whose channel mean is exactly wrong here:
//  BS.1770-4 weights and sums channels AFTER K-weighting each one separately, and
//  a true-peak meter is per-channel by definition. Down-mixing first would read
//  3.01 dB low on dual-mono material and hide an inter-channel peak entirely.
//
//  Decoders emit each codec's native sample format (float32 for WAV/MP3, packed
//  integer for FLAC, sometimes interleaved), so a non-standard layout is routed
//  through an `AVAudioConverter` exactly as `PCMDecoding.decodeAll` does.
//
//  PlayerCore portability: AVFAudio + Foundation + Decoding.
//

import AVFAudio
import Decoding
import Foundation

/// Pulls fixed-size windows from a ``PCMDecoding`` and exposes them as planar
/// float channel pointers.
///
/// Thread-confined, like the decoder it wraps: one pass owns one stream.
final class PlanarSampleStream {
    /// The stream's sample rate, in Hz.
    let sampleRate: Double

    /// The stream's channel count, in `L, R, C, LFE, Ls, Rs` order.
    let channelCount: Int

    private let decoder: any PCMDecoding
    private let url: URL
    private let capacity: AVAudioFrameCount
    private let scratch: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let converted: AVAudioPCMBuffer?

    /// - Parameters:
    ///   - decoder: An open decoder positioned at the start of the stream.
    ///   - url: The source URL, used only to describe failures.
    ///   - capacity: Frames pulled per ``read(_:)`` call.
    /// - Throws: ``LoudnessScanError/unreadableStream(url:)`` when the decoder's
    ///   format is unusable or its buffers cannot be allocated.
    init(decoder: any PCMDecoding, url: URL, capacity: AVAudioFrameCount) throws {
        let source = decoder.processingFormat
        guard
            source.sampleRate > 0,
            source.channelCount > 0,
            let floatFormat = AVAudioFormat(
                standardFormatWithSampleRate: source.sampleRate,
                channels: source.channelCount
            ),
            let scratch = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity)
        else {
            throw LoudnessScanError.unreadableStream(url: url)
        }

        if source == floatFormat {
            converter = nil
            converted = nil
        } else {
            guard
                let converter = AVAudioConverter(from: source, to: floatFormat),
                let converted = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: capacity)
            else {
                throw LoudnessScanError.unreadableStream(url: url)
            }
            self.converter = converter
            self.converted = converted
        }

        self.decoder = decoder
        self.url = url
        self.capacity = capacity
        self.scratch = scratch
        sampleRate = source.sampleRate
        channelCount = Int(source.channelCount)
    }

    /// Decodes the next window and hands its planar channels to `body`.
    ///
    /// `body` receives exactly ``channelCount`` pointers, each valid for the
    /// returned frame count and **only for the duration of the call** — the
    /// buffers are reused by the next pull. It is not invoked at end of stream.
    ///
    /// - Returns: How many frames were produced; `0` means end of stream.
    /// - Throws: ``LoudnessScanError/decodeFailed(url:reason:)`` when the decoder
    ///   or the float conversion fails part-way through.
    @discardableResult
    func read(_ body: ([UnsafePointer<Float>], Int) -> Void) throws -> Int {
        scratch.frameLength = 0
        let produced: AVAudioFrameCount
        do {
            produced = try decoder.decode(into: scratch, frameLength: capacity)
        } catch {
            throw LoudnessScanError.decodeFailed(url: url, reason: error.localizedDescription)
        }
        guard produced > 0 else { return 0 }
        let buffer = try normalised(scratch)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return 0 }
        let channels = (0 ..< channelCount).map { UnsafePointer(data[$0]) }
        body(channels, frames)
        return frames
    }

    // MARK: Private

    private func normalised(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter, let converted else { return source }
        converted.frameLength = 0
        do {
            try converter.convert(to: converted, from: source)
        } catch {
            throw LoudnessScanError.decodeFailed(
                url: url,
                reason: "float conversion failed: \(error.localizedDescription)"
            )
        }
        return converted
    }
}
