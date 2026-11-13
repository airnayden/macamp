@testable import AudioEngine
import AVFAudio
import Darwin
@testable import DSP
import Foundation
import Testing

// MARK: Fixtures

private enum StereoMeteringFixtureError: Error {
    case missingFormat
    case missingBuffer
    case missingChannelData
}

private let fixtureSampleRate: Double = 44100
private let fixtureFrequency: Double = 997
private let fixtureFrameCount: AVAudioFrameCount = 1024

/// A de-interleaved float tap buffer carrying one 997 Hz sine per entry in
/// `amplitudes` — `amplitudes.count` is therefore the buffer's channel count,
/// which is exactly what the tap's mono guard reads.
private func toneBuffer(
    amplitudes: [Float],
    frameCount: AVAudioFrameCount = fixtureFrameCount
) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
        standardFormatWithSampleRate: fixtureSampleRate,
        channels: AVAudioChannelCount(amplitudes.count)
    ) else {
        throw StereoMeteringFixtureError.missingFormat
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw StereoMeteringFixtureError.missingBuffer
    }
    buffer.frameLength = frameCount
    guard let channels = buffer.floatChannelData else {
        throw StereoMeteringFixtureError.missingChannelData
    }
    let increment = 2 * Double.pi * fixtureFrequency / fixtureSampleRate
    for (channel, amplitude) in amplitudes.enumerated() {
        for frame in 0 ..< Int(frameCount) {
            channels[channel][frame] = amplitude * Float(sin(increment * Double(frame)))
        }
    }
    return buffer
}

/// The dBFS a sine of `amplitude` peaks at — what its true-peak reading is
/// compared against, allowing for the BS.1770-4 filter's published +0.008 dB.
private func decibels(_ amplitude: Float) -> Float {
    20 * log10(amplitude)
}

/// `+3 dB` as a linear multiplier, so a full-scale sine becomes a clipping one.
private let boostOf3dB = Float(pow(10.0, 3.0 / 20.0))

private func mallocBlocksInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return Int(stats.blocks_in_use)
}

private func peek(_ provider: SpectrumProvider, channel: Int, count: Int = 1024) -> [Float] {
    var window = [Float](repeating: -999, count: count)
    window.withUnsafeMutableBufferPointer { buffer in
        provider.latestWindow(channel: channel, into: buffer, count: count)
    }
    return window
}

// MARK: - Tap ingest

@Suite(.serialized)
struct StereoTapIngestTests {
    @Test func stereoBufferFeedsBothChannelRings() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.25, 0.5]), into: provider)

        let reading = StereoPeakMeter().read(from: provider, channelCount: 2)

        #expect(!reading.isMono)
        #expect(abs(reading.left.dBTP - decibels(0.25)) < 0.3)
        #expect(abs(reading.right.dBTP - decibels(0.5)) < 0.3)
    }

    @Test func monoBufferLeavesTheChannelOneRingUnwritten() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.5]), into: provider)

        #expect(peek(provider, channel: 0).contains { $0 != 0 })
        #expect(peek(provider, channel: 1).allSatisfy { $0 == 0 })
    }

    @Test func monoSourceMirrorsChannelZeroOntoChannelOne() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.5]), into: provider)

        let reading = StereoPeakMeter().read(from: provider, channelCount: 1)

        #expect(reading.isMono)
        #expect(reading.right == reading.left)
        #expect(abs(reading.left.dBTP - decibels(0.5)) < 0.3)
    }

    @Test func spectrumStillReadsChannelZeroAfterTheStereoWiden() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.9, 0], frameCount: 4096), into: provider)

        #expect(provider.latestSpectrum().contains { $0 > 0 })
    }

    @Test func unmeteredChannelRequestLeavesTheDestinationUntouched() {
        let provider = SpectrumProvider()

        #expect(peek(provider, channel: 2).allSatisfy { $0 == -999 })
    }
}

// MARK: - Clip indicator

@Suite(.serialized)
struct StereoClipIndicatorTests {
    @Test func boostedFullScaleSineReadsAboveZeroDBTPAndClips() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [boostOf3dB, boostOf3dB]), into: provider)

        let reading = StereoPeakMeter().read(from: provider, channelCount: 2)

        #expect(reading.left.dBTP > 0)
        #expect(reading.right.dBTP > 0)
        #expect(reading.isClipping)
        #expect(abs(reading.loudest.dBTP - 3) < 0.3)
    }

    @Test func oneHotChannelIsEnoughToClip() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.1, boostOf3dB]), into: provider)

        let reading = StereoPeakMeter().read(from: provider, channelCount: 2)

        #expect(reading.isClipping)
        #expect(reading.loudest == reading.right)
    }

    @Test func comfortableHeadroomDoesNotClip() throws {
        let provider = SpectrumProvider()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.5, 0.5]), into: provider)

        let reading = StereoPeakMeter().read(from: provider, channelCount: 2)

        #expect(!reading.isClipping)
        #expect(reading.loudest.dBTP < StereoPeakMeter.clipThresholdDBTP)
    }

    @Test func silenceNeverClips() {
        let reading = StereoPeakMeter().read(from: SpectrumProvider(), channelCount: 2)

        #expect(reading.left.dBTP == -.infinity)
        #expect(!reading.isClipping)
    }
}

// MARK: - Stereo to mono transition

@Suite(.serialized)
struct StereoToMonoTransitionTests {
    /// The case a fresh zeroed ring cannot cover: channel 1 holds a LOUD stereo
    /// window that the non-destructive peek would happily replay for the whole of
    /// a following mono track, latching the clip light on a source that cannot
    /// clip. Only the consumer-side channel count stops it.
    @Test func monoAfterStereoMirrorsChannelZeroRatherThanTheStaleRing() throws {
        let provider = SpectrumProvider()
        let meter = StereoPeakMeter()

        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.1, boostOf3dB]), into: provider)
        let stereo = meter.read(from: provider, channelCount: 2)
        #expect(!stereo.isMono)
        #expect(stereo.isClipping)

        let mono = try toneBuffer(amplitudes: [0.1])
        SFBPlaybackEngine.ingest(mono, into: provider)
        SFBPlaybackEngine.ingest(mono, into: provider)
        let monoReading = meter.read(from: provider, channelCount: 1)

        #expect(monoReading.isMono)
        #expect(monoReading.right == monoReading.left)
        #expect(!monoReading.isClipping)
        #expect(abs(monoReading.left.dBTP - decibels(0.1)) < 0.3)

        // Negative control: the loud stereo window really is still in the ring,
        // so the mono verdict came from the channel count and nothing else.
        let control = StereoPeakMeter().read(from: provider, channelCount: 2)
        #expect(control.isClipping)
        #expect(control.right.dBTP > 0)
    }

    @Test func returningToStereoMeasuresChannelOneAgain() throws {
        let provider = SpectrumProvider()
        let meter = StereoPeakMeter()

        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.1]), into: provider)
        #expect(meter.read(from: provider, channelCount: 1).isMono)

        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [0.1, 0.5]), into: provider)
        let reading = meter.read(from: provider, channelCount: 2)

        #expect(!reading.isMono)
        #expect(abs(reading.right.dBTP - decibels(0.5)) < 0.3)
    }

    @Test func resetClearsThePublishedReading() throws {
        let provider = SpectrumProvider()
        let meter = StereoPeakMeter()
        try SFBPlaybackEngine.ingest(toneBuffer(amplitudes: [boostOf3dB, boostOf3dB]), into: provider)
        meter.read(from: provider, channelCount: 2)
        #expect(meter.reading.isClipping)

        meter.reset()

        #expect(meter.reading == .silence)
        #expect(!meter.reading.isClipping)
    }
}

// MARK: - Audio-thread allocation

@Suite(.serialized)
struct StereoTapAllocationTests {
    @Test func tapPathIsZeroAllocationWithTheStereoRingActive() throws {
        let provider = SpectrumProvider()
        let buffer = try toneBuffer(amplitudes: [0.5, 0.25])
        let iterations = 200_000

        for _ in 0 ..< 2000 {
            SFBPlaybackEngine.ingest(buffer, into: provider)
        }

        // The default malloc zone counter is process-global, so a concurrently
        // running suite lands in the delta too. The control window (no ingest)
        // measures that ambient noise to subtract it.
        var sink = 0
        let controlStart = mallocBlocksInUse()
        for index in 0 ..< iterations {
            sink = sink &+ (index & 1)
        }
        let ambient = mallocBlocksInUse() - controlStart
        _ = sink

        let ingestStart = mallocBlocksInUse()
        for _ in 0 ..< iterations {
            SFBPlaybackEngine.ingest(buffer, into: provider)
        }
        let ingestDelta = mallocBlocksInUse() - ingestStart

        // A per-call allocation regression would add ~2e5 blocks; two memcpys into
        // two pre-allocated rings only track ambient noise.
        #expect(ingestDelta <= max(ambient, 0) + 4096)
    }
}
