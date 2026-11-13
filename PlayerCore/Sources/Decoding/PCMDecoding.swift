// PCMDecoding — the module-level decode abstraction.
//
// `PCMDecoding` is the narrow, PCM-only protocol that every decoder in the
// Decoding module exposes, regardless of the source codec. The real backend
// (``SFBDecoderProvider``) wraps SFBAudioEngine's `AudioDecoder` / DSD→PCM
// pipeline; the test backend (``FakeDecoderProvider``) synthesises samples.
// Both vend `any PCMDecoding`, so the audio engine (Task 9) and the tests are
// written once against this protocol and never see SFB types directly.
//
// By contract the output is ALWAYS linear PCM (DSD is decimated to PCM upstream)
// in `processingFormat`. This file imports only AVFAudio + Foundation; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

/// A pull-based linear-PCM decoder for a single audio source.
///
/// Instances are **single-threaded / thread-confined**: the owner decodes,
/// seeks and inspects position from one thread (the engine's scheduling thread
/// or a test). The protocol is therefore class-bound but intentionally *not*
/// `Sendable` — the `Sendable` surface of the module is the *provider*
/// (``DecoderProviding``), not the live decoder.
public protocol PCMDecoding: AnyObject {
    /// The PCM format the decoder emits from ``decode(into:frameLength:)``.
    ///
    /// Always linear PCM (never DSD): DSD sources are decimated to PCM before
    /// they reach a caller. Typically 32-bit float, deinterleaved, at the
    /// source's native sample rate and channel count.
    var processingFormat: AVAudioFormat { get }

    /// The native format of the source stream, when the backend exposes it.
    ///
    /// Informational only (e.g. "DSD64 1-bit @ 2.8224 MHz" before decimation);
    /// `nil` when the backend does not surface a distinct source format.
    var sourceFormat: AVAudioFormat? { get }

    /// Total number of PCM frames in the stream, or `-1` when unknown.
    var frameLength: AVAudioFramePosition { get }

    /// The decoder's current read position, in PCM frames from the start.
    var framePosition: AVAudioFramePosition { get }

    /// `true` when the backend can reposition the read head via ``seek(toFrame:)``.
    var supportsSeeking: Bool { get }

    /// Decodes up to `frameLength` frames into `buffer`.
    ///
    /// Sets `buffer.frameLength` to the number of frames actually produced and
    /// returns the same count. A return of `0` means end-of-stream. The buffer
    /// must have been allocated with ``processingFormat``.
    ///
    /// - Throws: ``DecodingError`` on malformed / truncated / unreadable input.
    @discardableResult
    func decode(into buffer: AVAudioPCMBuffer, frameLength: AVAudioFrameCount) throws -> AVAudioFrameCount

    /// Repositions the read head to `frame` (frames from the start).
    ///
    /// - Returns: The frame actually sought to (backends may snap to a packet).
    /// - Throws: ``DecodingError`` when seeking fails on a seekable stream.
    @discardableResult
    func seek(toFrame frame: AVAudioFramePosition) throws -> AVAudioFramePosition
}

// MARK: - Convenience

public extension PCMDecoding {
    /// Decodes the **entire remaining stream** into one contiguous buffer.
    ///
    /// Convenience for tests, the `macamp-cli decode` command, and offline
    /// analysis — it accumulates the whole file in memory and is therefore NOT
    /// suitable for the real-time render path (the engine pulls fixed blocks via
    /// ``decode(into:frameLength:)`` instead).
    ///
    /// The result is always a deinterleaved 32-bit-float buffer so that the
    /// analysis helpers (`floatChannelData`) work regardless of the backend's
    /// interleaving, converting on the fly when necessary.
    ///
    /// - Parameter blockSize: Frames pulled from the decoder per iteration.
    /// - Returns: A single buffer holding every decoded frame (may be empty).
    /// - Throws: ``DecodingError`` propagated from ``decode(into:frameLength:)``.
    func decodeAll(blockSize: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        let block = max(blockSize, 1)
        let sourceFormat = processingFormat
        let sampleRate = sourceFormat.sampleRate > 0 ? sourceFormat.sampleRate : 44100
        let channelCount = AVAudioChannelCount(max(sourceFormat.channelCount, 1))

        guard
            let floatFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount),
            let scratch = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: block)
        else {
            throw DecodingError.corruptedFile(url: Self.streamURL, reason: "could not allocate decode buffers")
        }

        // SFB returns each codec's *native* sample format — float32 for WAV/MP3,
        // packed integer for FLAC, etc. Normalise every block to deinterleaved
        // float32 through an AVAudioConverter so callers always see real samples
        // via `floatChannelData` regardless of the source bit depth / layout.
        let normaliser = try FloatNormaliser(source: sourceFormat, target: floatFormat, capacity: block)

        var channels = [[Float]](repeating: [], count: Int(channelCount))
        while true {
            let produced = try decode(into: scratch, frameLength: block)
            if produced == 0 { break }
            let floatBuffer = try normaliser.normalise(scratch)
            appendSamples(from: floatBuffer, produced: Int(floatBuffer.frameLength), into: &channels)
        }

        return Self.makeFloatBuffer(channels: channels, sampleRate: sampleRate)
    }

    /// Synthetic URL used only for the messages of the (effectively impossible)
    /// internal allocation/conversion errors `decodeAll` can raise.
    private static var streamURL: URL {
        URL(fileURLWithPath: "decodeAll")
    }

    /// Appends `produced` deinterleaved-float frames of each channel onto the
    /// accumulators. The buffer is always float32 (the `FloatNormaliser` upstream
    /// guarantees it), so `floatChannelData` is non-nil for valid input.
    private func appendSamples(
        from buffer: AVAudioPCMBuffer,
        produced: Int,
        into channels: inout [[Float]]
    ) {
        guard let data = buffer.floatChannelData else { return }
        for channel in 0 ..< channels.count {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: produced))
        }
    }

    /// Builds a deinterleaved float buffer from per-channel sample arrays.
    /// `fatalError` only on the impossible case (banned `force_unwrapping`
    /// escape hatch for a genuine invariant; mirrors `SignalGenerators`).
    private static func makeFloatBuffer(channels: [[Float]], sampleRate: Double) -> AVAudioPCMBuffer {
        let channelCount = AVAudioChannelCount(max(channels.count, 1))
        let frames = AVAudioFrameCount(channels.first?.count ?? 0)
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 44100,
                channels: channelCount
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))
        else {
            fatalError("standard float buffer is unconstructible at \(sampleRate) Hz / \(channelCount) ch")
        }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData {
            for channel in 0 ..< Int(channelCount) where channel < channels.count {
                channels[channel].withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    data[channel].update(from: base, count: Int(frames))
                }
            }
        }
        return buffer
    }
}

// MARK: - Float normalisation

/// Converts decoder output of any sample format to deinterleaved float32.
///
/// When the source is already standard float32 the conversion is a passthrough;
/// otherwise an `AVAudioConverter` performs the bit-depth / interleaving change
/// (same sample rate, so the one-shot `convert(to:from:)` is sufficient).
private struct FloatNormaliser {
    private let converter: AVAudioConverter?
    private let scratch: AVAudioPCMBuffer?

    init(source: AVAudioFormat, target: AVAudioFormat, capacity: AVAudioFrameCount) throws {
        if source == target {
            converter = nil
            scratch = nil
            return
        }
        guard
            let converter = AVAudioConverter(from: source, to: target),
            let scratch = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else {
            throw DecodingError.corruptedFile(
                url: URL(fileURLWithPath: "decodeAll"),
                reason: "cannot convert source format to float32"
            )
        }
        self.converter = converter
        self.scratch = scratch
    }

    func normalise(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter, let scratch else { return source }
        scratch.frameLength = 0
        do {
            try converter.convert(to: scratch, from: source)
        } catch {
            throw DecodingError.corruptedFile(
                url: URL(fileURLWithPath: "decodeAll"),
                reason: "float conversion failed: \(error.localizedDescription)"
            )
        }
        return scratch
    }
}
