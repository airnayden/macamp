// MonoSampleStream — bounded windowed pulls from a decoder, as mono float.
//
// The feature pass needs one thing from a file: a sequence of mono float samples
// it can fold into running accumulators. This wrapper supplies exactly that,
// a window at a time:
//
//   decoder.decode(into:frameLength:)  →  float32 normalisation  →  channel mean
//
// The whole track is NEVER materialised — only `capacity` frames exist at once,
// so a five-minute stereo file costs ~4 KB of PCM instead of ~100 MB. This is
// deliberately NOT `Separation.WindowedFloatDecoder`, which concatenates every
// block into one whole-track buffer; only its off-thread discipline transfers.
//
// Decoders emit each codec's native sample format (float32 for WAV/MP3, packed
// integer for FLAC, sometimes interleaved), so a non-standard layout is routed
// through an `AVAudioConverter` exactly like `PCMDecoding.decodeAll` does.
//
// PlayerCore portability: AVFAudio + Accelerate + Foundation + Decoding.
import Accelerate
import AVFAudio
import Decoding
import Foundation

/// Pulls fixed-size windows from a ``PCMDecoding`` and hands back mono float samples.
///
/// Thread-confined, like the decoder it wraps: one pass owns one stream.
final class MonoSampleStream {
    /// The stream's sample rate, in Hz.
    let sampleRate: Double

    private let decoder: any PCMDecoding
    private let url: URL
    private let capacity: AVAudioFrameCount
    private let scratch: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let converted: AVAudioPCMBuffer?

    /// - Parameters:
    ///   - decoder: An open decoder positioned at the start of the stream.
    ///   - url: The source URL, used only to describe failures.
    ///   - capacity: Frames pulled per ``readMono(into:)`` call.
    /// - Throws: ``AudioFeatureError/unreadableStream(url:)`` when the decoder's
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
            throw AudioFeatureError.unreadableStream(url: url)
        }

        if source == floatFormat {
            converter = nil
            converted = nil
        } else {
            guard
                let converter = AVAudioConverter(from: source, to: floatFormat),
                let converted = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: capacity)
            else {
                throw AudioFeatureError.unreadableStream(url: url)
            }
            self.converter = converter
            self.converted = converted
        }

        self.decoder = decoder
        self.url = url
        self.capacity = capacity
        self.scratch = scratch
        sampleRate = source.sampleRate
    }

    /// Decodes the next window and writes its channel mean into `destination`.
    ///
    /// - Parameter destination: A buffer of at least `capacity` elements; only
    ///   the returned prefix is written.
    /// - Returns: How many mono samples were produced; `0` means end of stream.
    /// - Throws: ``AudioFeatureError/decodeFailed(url:reason:)`` when the decoder
    ///   or the float conversion fails part-way through.
    func readMono(into destination: inout [Float]) throws -> Int {
        scratch.frameLength = 0
        let produced: AVAudioFrameCount
        do {
            produced = try decoder.decode(into: scratch, frameLength: capacity)
        } catch {
            throw AudioFeatureError.decodeFailed(url: url, reason: error.localizedDescription)
        }
        guard produced > 0 else { return 0 }
        let buffer = try normalised(scratch)
        let count = min(Int(buffer.frameLength), destination.count)
        guard count > 0 else { return 0 }
        downmix(buffer, count: count, into: &destination)
        return count
    }

    // MARK: Private

    private func normalised(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter, let converted else { return source }
        converted.frameLength = 0
        do {
            try converter.convert(to: converted, from: source)
        } catch {
            throw AudioFeatureError.decodeFailed(
                url: url,
                reason: "float conversion failed: \(error.localizedDescription)"
            )
        }
        return converted
    }

    /// Averages every channel into `destination` — the analyzer is mono, and a
    /// plain mean keeps a centred mix at full level instead of the −3 dB an
    /// `AVAudioMixerNode` pan law would apply.
    private func downmix(_ buffer: AVAudioPCMBuffer, count: Int, into destination: inout [Float]) {
        guard let data = buffer.floatChannelData else {
            for index in 0 ..< count {
                destination[index] = 0
            }
            return
        }
        let channels = Int(buffer.format.channelCount)
        destination.withUnsafeMutableBufferPointer { output in
            guard let base = output.baseAddress else { return }
            base.update(from: data[0], count: count)
            guard channels > 1 else { return }
            for channel in 1 ..< channels {
                vDSP_vadd(base, 1, data[channel], 1, base, 1, vDSP_Length(count))
            }
            var divisor = Float(channels)
            vDSP_vsdiv(base, 1, &divisor, base, 1, vDSP_Length(count))
        }
    }
}
