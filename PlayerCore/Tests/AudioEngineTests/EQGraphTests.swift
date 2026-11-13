@testable import AudioEngine
import AVFAudio
import PlayerCoreTestSupport
import Testing

/// Renders a sine through the real ten-band EQ in an offline graph and measures
/// the result. The graph is `source → EQ → outputNode` (NOT via `mainMixerNode`)
/// so the −3 dB equal-power mono pan law never corrupts the level assertions
/// (see the OfflineRenderHarness gotcha note).
@Suite(.serialized)
struct EQGraphTests {
    private let sampleRate = 44100.0

    private func renderSineThroughEQ(
        frequency: Double,
        amplitude: Float = 0.9,
        configure: (AVAudioUnitEQ) -> Void
    ) throws -> AVAudioPCMBuffer {
        let format = SignalGenerators.monoFormat(sampleRate: sampleRate)
        return try OfflineRenderHarness.render(format: format, duration: 1.0) { engine in
            let source = SignalGenerators.sine(frequency: frequency, sampleRate: sampleRate, amplitude: amplitude)
            let equalizer = makeEQUnit()
            configure(equalizer)
            engine.attach(source)
            engine.attach(equalizer)
            engine.connect(source, to: equalizer, format: format)
            return equalizer
        }
    }

    @Test("cutting the band centred on 1 kHz materially reduces a 1 kHz tone")
    func bandCutReducesEnergy() throws {
        let baseline = try renderSineThroughEQ(frequency: 1000) { _ in }
        let cut = try renderSineThroughEQ(frequency: 1000) { equalizer in
            equalizer.bands[EQBand.hz1k.rawValue].gain = -24
        }
        let baselineRMS = Analysis.rms(buffer: baseline)
        let cutRMS = Analysis.rms(buffer: cut)
        #expect(baselineRMS > 0.1, "baseline RMS \(baselineRMS)")
        #expect(cutRMS < baselineRMS * 0.5, "cut RMS \(cutRMS) vs baseline \(baselineRMS)")
    }

    @Test("a -6 dB global gain lowers output by ~6 dB without clipping")
    func globalGainAttenuatesCleanly() throws {
        let baseline = try renderSineThroughEQ(frequency: 1000, amplitude: 0.9) { _ in }
        let attenuated = try renderSineThroughEQ(frequency: 1000, amplitude: 0.9) { equalizer in
            equalizer.globalGain = -6
        }
        let baselineDB = Analysis.dBFS(buffer: baseline)
        let attenuatedDB = Analysis.dBFS(buffer: attenuated)
        let delta = baselineDB - attenuatedDB
        #expect(abs(delta - 6) < 0.5, "attenuation \(delta) dB (expected 6)")
        #expect(!Analysis.isClipped(buffer: attenuated), "attenuated output clipped")
        #expect(!Analysis.isClipped(buffer: baseline), "baseline output clipped")
    }

    @Test("a flat EQ passes a 1 kHz tone through near-transparently")
    func flatEQIsTransparent() throws {
        let through = try renderSineThroughEQ(frequency: 1000, amplitude: 0.9) { _ in }
        let peak = Analysis.peak(buffer: through)
        #expect(peak > 0.7, "flat-EQ peak \(peak) too low")
        #expect(peak < 1.0, "flat-EQ peak \(peak) clipped")
    }
}
