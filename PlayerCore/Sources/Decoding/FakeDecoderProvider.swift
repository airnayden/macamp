// FakeDecoderProvider — a deterministic, file-free decoder backend for tests.
//
// Higher layers (the audio engine in Task 9, view-models, the gapless
// scheduler) need to exercise the decode path without shipping binary fixtures
// or touching SFBAudioEngine. This provider synthesises a pure sine tone whose
// samples are a closed-form function of the absolute frame index, so output is
// byte-for-byte reproducible and seeking is exact. It can also be configured to
// fail for chosen extensions, so callers can test their ``DecodingError``
// handling deterministically.
//
// This file imports only AVFAudio + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

/// A ``DecoderProviding`` backend that vends synthetic PCM instead of reading
/// files — the test/double counterpart to ``SFBDecoderProvider``.
public struct FakeDecoderProvider: DecoderProviding {
    /// Tone frequency in Hz produced by every decoder this provider vends.
    public let frequency: Double
    /// Output sample rate in Hz.
    public let sampleRate: Double
    /// Output channel count (the same tone is written to every channel).
    public let channelCount: AVAudioChannelCount
    /// Stream length in seconds.
    public let duration: Double
    /// Linear peak amplitude (default 0.9, just below full scale).
    public let amplitude: Float
    /// Extensions that ``makeDecoder(for:)`` rejects as `.unsupportedFormat`.
    public let unsupportedExtensions: Set<String>
    /// Extensions that ``makeDecoder(for:)`` rejects as `.corruptedFile`.
    public let corruptExtensions: Set<String>

    public init(
        frequency: Double = 440,
        sampleRate: Double = 44100,
        channelCount: AVAudioChannelCount = 1,
        duration: Double = 1.0,
        amplitude: Float = 0.9,
        unsupportedExtensions: Set<String> = [],
        corruptExtensions: Set<String> = []
    ) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        self.duration = duration
        self.amplitude = amplitude
        self.unsupportedExtensions = unsupportedExtensions
        self.corruptExtensions = corruptExtensions
    }

    public func makeDecoder(for url: URL) throws -> any PCMDecoding {
        try makeDecoder(for: url, frameRange: nil)
    }

    public func makeDecoder(for source: DecoderSource) throws -> any PCMDecoding {
        try makeDecoder(for: source.url, frameRange: source.frameRange)
    }

    private func makeDecoder(
        for url: URL,
        frameRange: Range<AVAudioFramePosition>?
    ) throws -> any PCMDecoding {
        let ext = url.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            throw DecodingError.unsupportedFormat(url: url)
        }
        if corruptExtensions.contains(ext) {
            throw DecodingError.corruptedFile(url: url, reason: "injected by FakeDecoderProvider")
        }
        return FakePCMDecoder(
            frequency: frequency,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration,
            amplitude: amplitude,
            frameRange: frameRange
        )
    }

    public static let supportedPathExtensions: Set<String> = ["wav", "aiff", "flac", "mp3", "caf", "fake"]
    public static let supportedMIMETypes: Set<String> = ["audio/wav", "audio/aiff", "audio/flac", "audio/mpeg"]
}

/// A ``PCMDecoding`` whose samples are the closed-form sine
/// `amplitude · sin(2π · frequency · n / sampleRate)` at absolute frame `n`.
///
/// Because each sample depends only on its absolute index, decoding is
/// stateless apart from the read cursor and ``seek(toFrame:)`` is exact — there
/// is no codec state to rebuild.
final class FakePCMDecoder: PCMDecoding {
    let processingFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat? = nil
    let frameLength: AVAudioFramePosition
    private(set) var framePosition: AVAudioFramePosition = 0
    let supportsSeeking = true

    private let angularIncrement: Double
    private let amplitude: Float
    private let channels: Int
    /// Absolute frame the region starts at. ``framePosition`` stays
    /// region-relative (matching SFB's `AudioRegionDecoder`), so the tone's phase
    /// is derived from `regionStart + framePosition` and a region therefore
    /// carries exactly the samples it would inside the full stream.
    private let regionStart: AVAudioFramePosition

    init(
        frequency: Double,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        duration: Double,
        amplitude: Float,
        frameRange: Range<AVAudioFramePosition>? = nil
    ) {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
        else {
            fatalError("standard float format unconstructible at \(sampleRate) Hz / \(channelCount) ch")
        }
        processingFormat = format
        let streamLength = AVAudioFramePosition((duration * sampleRate).rounded())
        regionStart = min(max(frameRange?.lowerBound ?? 0, 0), streamLength)
        frameLength = min(frameRange?.upperBound ?? streamLength, streamLength) - regionStart
        angularIncrement = 2.0 * Double.pi * frequency / sampleRate
        self.amplitude = amplitude
        channels = Int(channelCount)
    }

    @discardableResult
    func decode(into buffer: AVAudioPCMBuffer, frameLength frames: AVAudioFrameCount) throws -> AVAudioFrameCount {
        let remaining = frameLength - framePosition
        guard remaining > 0, let data = buffer.floatChannelData else {
            buffer.frameLength = 0
            return 0
        }
        let toProduce = min(Int(frames), Int(buffer.frameCapacity), Int(remaining))
        for channel in 0 ..< min(channels, Int(buffer.format.channelCount)) {
            for frame in 0 ..< toProduce {
                let index = Double(regionStart + framePosition + AVAudioFramePosition(frame))
                data[channel][frame] = amplitude * Float(sin(angularIncrement * index))
            }
        }
        buffer.frameLength = AVAudioFrameCount(toProduce)
        framePosition += AVAudioFramePosition(toProduce)
        return AVAudioFrameCount(toProduce)
    }

    @discardableResult
    func seek(toFrame frame: AVAudioFramePosition) throws -> AVAudioFramePosition {
        framePosition = max(0, min(frame, frameLength))
        return framePosition
    }
}
