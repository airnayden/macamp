// SpectralIntegrityAnalyzer — the file-level fake-lossless heuristic.
//
// Streams a file through ``SpectralCutoffEstimator`` in bounded blocks and reads
// the resulting cutoff with ``FakeLosslessRule``. Nothing it returns is proof; see
// `FakeLosslessVerdict` for the contract on how the result may be worded.
//
// The decode is WINDOWED: one `decodeBlockFrames`-sized buffer is reused for the
// whole stream, so a ten-minute file costs the same memory as a ten-second one.
// It NEVER runs on the main actor — the work goes to a detached utility task, and
// cancellation reaches the decode loop through `withTaskCancellationHandler`, the
// same construction `AudioFeatureExtractor` and `LoudnessScanner` use.
//
// PlayerCore portability: AVFAudio + Decoding + DSP + Foundation.
import AVFAudio
import Decoding
import DSP
import Foundation

public enum SpectralIntegrityError: Error, Sendable, Equatable {
    /// Working buffers for the stream's own format could not be built.
    case analysisSetupFailed(url: URL)
}

/// Inspects a file's spectrum for the band-limiting a lossy encoder leaves behind.
public protocol SpectralIntegrityChecking: Sendable {
    func inspect(_ url: URL) async throws -> FakeLosslessVerdict
}

public struct SpectralIntegrityAnalyzer: SpectralIntegrityChecking {
    /// Frames pulled per decode iteration. Large enough that a full analysis window
    /// lands inside two pulls, small enough that peak memory stays flat.
    public static let decodeBlockFrames: AVAudioFrameCount = 8192

    private let decoderProvider: any DecoderProviding

    public init(decoderProvider: any DecoderProviding = SFBDecoderProvider()) {
        self.decoderProvider = decoderProvider
    }

    public func inspect(_ url: URL) async throws -> FakeLosslessVerdict {
        let provider = decoderProvider
        let work = Task.detached(priority: .utility) {
            try Self.analyze(url, using: provider)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Analysis

    private static func analyze(_ url: URL, using provider: any DecoderProviding) throws -> FakeLosslessVerdict {
        let decoder = try provider.makeDecoder(for: url)
        let sourceFormat = decoder.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            return .indeterminate(.unusableSampleRate)
        }
        let estimator = SpectralCutoffEstimator(sampleRate: sourceFormat.sampleRate)
        try drain(decoder, url: url, into: estimator)
        return FakeLosslessRule.verdict(for: estimator.finish())
    }

    private static func drain(
        _ decoder: any PCMDecoding,
        url: URL,
        into estimator: SpectralCutoffEstimator
    ) throws {
        let sourceFormat = decoder.processingFormat
        let channelCount = AVAudioChannelCount(max(sourceFormat.channelCount, 1))
        guard
            let floatFormat = AVAudioFormat(
                standardFormatWithSampleRate: sourceFormat.sampleRate,
                channels: channelCount
            ),
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: decodeBlockFrames)
        else {
            throw SpectralIntegrityError.analysisSetupFailed(url: url)
        }
        let conversion = try makeConversion(from: sourceFormat, to: floatFormat, url: url)
        var mono = [Float](repeating: 0, count: Int(decodeBlockFrames))

        while true {
            try Task.checkCancellation()
            let produced = try decoder.decode(into: source, frameLength: decodeBlockFrames)
            if produced == 0 { break }
            let block = try convert(source, using: conversion, url: url)
            feed(block, into: estimator, scratch: &mono)
        }
    }

    // MARK: - Float normalisation

    /// `nil` means the decoder already emits deinterleaved float32 at the stream's
    /// own rate, so its buffer can be read directly with no conversion stage.
    private typealias Conversion = (converter: AVAudioConverter, destination: AVAudioPCMBuffer)?

    private static func makeConversion(
        from sourceFormat: AVAudioFormat,
        to floatFormat: AVAudioFormat,
        url: URL
    ) throws -> Conversion {
        if sourceFormat.commonFormat == .pcmFormatFloat32,
           !sourceFormat.isInterleaved,
           sourceFormat.channelCount == floatFormat.channelCount,
           sourceFormat.sampleRate == floatFormat.sampleRate
        {
            return nil
        }
        guard
            let converter = AVAudioConverter(from: sourceFormat, to: floatFormat),
            let destination = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: decodeBlockFrames)
        else {
            throw SpectralIntegrityError.analysisSetupFailed(url: url)
        }
        return (converter, destination)
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        using conversion: Conversion,
        url: URL
    ) throws -> AVAudioPCMBuffer {
        guard let conversion else { return source }
        conversion.destination.frameLength = 0
        do {
            try conversion.converter.convert(to: conversion.destination, from: source)
        } catch {
            throw SpectralIntegrityError.analysisSetupFailed(url: url)
        }
        return conversion.destination
    }

    /// Averages every channel into `scratch` and hands that window to the estimator.
    ///
    /// A plain mean, matching what the committed fixtures were measured with. The
    /// cutoff is a per-channel property of the encoder's lowpass, so any downmix
    /// that does not cancel channels preserves it.
    private static func feed(
        _ buffer: AVAudioPCMBuffer,
        into estimator: SpectralCutoffEstimator,
        scratch: inout [Float]
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = min(Int(buffer.frameLength), scratch.count)
        guard frames > 0 else { return }
        let channelCount = max(Int(buffer.format.channelCount), 1)
        let scale = 1 / Float(channelCount)

        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channelCount {
                sum += channels[channel][frame]
            }
            scratch[frame] = sum * scale
        }
        scratch.withUnsafeBufferPointer { buffer in
            estimator.append(UnsafeBufferPointer(rebasing: buffer[0 ..< frames]))
        }
    }
}
