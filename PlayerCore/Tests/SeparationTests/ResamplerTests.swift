import AudioToolbox

// ResamplerTests — offline normalisation to the model-native 44.1 kHz / stereo /
// deinterleaved float32 format. Frequency preservation is measured with the shared
// `Analysis.peakBin` FFT helper (from PlayerCoreTestSupport), never re-implemented.
import AVFAudio
import PlayerCoreTestSupport
@testable import Separation
import Testing

struct ResamplerTests {
    // MARK: - Happy path

    /// A 48 kHz sine, resampled to 44.1 kHz, keeps its frequency (within 1 Hz).
    ///
    /// `Analysis.peakBin` resolves to 44_100 / 4096 ≈ 10.77 Hz bins, so the source
    /// tone is placed exactly on an output bin centre: a correct resample lands the
    /// peak on that same bin (≈ 0 Hz error), while a wrong ratio would shift it many
    /// bins away (≫ 1 Hz), failing the assertion.
    @Test func resample48kToPreservesFrequency() throws {
        let binWidth = Resampler.targetSampleRate / 4096
        let frequency = binWidth * 93 // ≈ 1001.3 Hz — an exact 44.1 kHz FFT bin centre.
        let input = try Self.sineBuffer(frequency: frequency, sampleRate: 48000, channels: 1, seconds: 0.5)

        let output = try Resampler().normalise(input)

        #expect(output.format.sampleRate == 44100)
        #expect(output.format.channelCount == 2)
        let measured = Analysis.peakBin(buffer: output).frequency
        #expect(abs(measured - frequency) < 1.0)
    }

    /// Mono input is duplicated into two sample-identical channels.
    @Test func monoDuplicatesToTwoIdenticalChannels() throws {
        let input = try Self.sineBuffer(frequency: 1000, sampleRate: 44100, channels: 1, seconds: 0.25)

        let output = try Resampler().normalise(input)

        #expect(output.format.channelCount == 2)
        #expect(output.frameLength == input.frameLength)
        let data = try #require(output.floatChannelData)
        let frames = Int(output.frameLength)
        var identical = true
        for frame in 0 ..< frames where data[0][frame] != data[1][frame] {
            identical = false
            break
        }
        #expect(identical)
    }

    /// Already-44.1 kHz stereo passes through untouched — the same buffer, no copy.
    @Test func stereo44kPassesThroughUnchanged() throws {
        let input = try Self.sineBuffer(frequency: 1000, sampleRate: 44100, channels: 2, seconds: 0.1)

        let output = try Resampler().normalise(input)

        #expect(output === input)
    }

    // MARK: - Failure path

    /// A 5.1 (six-channel) buffer is rejected as an unsupported channel layout.
    @Test func surroundThrowsUnsupportedChannelLayout() throws {
        let input = try Self.sineBuffer(frequency: 440, sampleRate: 44100, channels: 6, seconds: 0.1)

        #expect(throws: SeparationError.unsupportedChannelLayout) {
            _ = try Resampler().normalise(input)
        }
    }

    // MARK: - Fixtures

    /// Builds a deinterleaved float32 sine buffer with `channels` identical channels.
    private static func sineBuffer(
        frequency: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double
    ) throws -> AVAudioPCMBuffer {
        let format = try makeFormat(sampleRate: sampleRate, channels: channels)
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        let data = try #require(buffer.floatChannelData)
        let increment = 2 * Double.pi * frequency / sampleRate
        for channel in 0 ..< Int(channels) {
            var phase = 0.0
            for frame in 0 ..< Int(frames) {
                data[channel][frame] = Float(sin(phase)) * 0.9
                phase += increment
                if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
            }
        }
        buffer.frameLength = frames
        return buffer
    }

    /// A deinterleaved float32 format. More than two channels use an explicit 5.1
    /// layout because the convenience initialiser rejects > 2 channels without one.
    private static func makeFormat(
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> AVAudioFormat {
        if channels <= 2 {
            return try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            ))
        }
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }
}
