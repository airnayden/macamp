// ReplayGainRenderTests — corroborates the computed gain end-to-end by rendering
// a real tone through the production EQ's `globalGain` (the exact path the engine
// uses for ReplayGain) and measuring the result: the right attenuation, and no
// clipping when anti-clip is in force.
//
// Graph is `source → EQ → outputNode` (NOT mainMixerNode — the −3 dB equal-power
// mono pan law there would corrupt the level assertions; see the harness note).
import AudioEngine // makeEQUnit
import AVFAudio
import Foundation
import Metadata // ReplayGain
import PlayerCoreTestSupport
@testable import Services
import Testing

@Suite(.serialized)
struct ReplayGainRenderTests {
    private let sampleRate = 44100.0
    private let calc = ReplayGainCalculator()

    private func renderSine(amplitude: Float, globalGainDB: Double) throws -> AVAudioPCMBuffer {
        let format = SignalGenerators.monoFormat(sampleRate: sampleRate)
        return try OfflineRenderHarness.render(format: format, duration: 1.0) { engine in
            let source = SignalGenerators.sine(frequency: 1000, sampleRate: sampleRate, amplitude: amplitude)
            let equalizer = makeEQUnit()
            equalizer.globalGain = Float(globalGainDB)
            engine.attach(source)
            engine.attach(equalizer)
            engine.connect(source, to: equalizer, format: format)
            return equalizer
        }
    }

    @Test("a tone rendered at the computed track gain attenuates by ~the gain, no clip")
    func computedGainRendersAtExpectedLevel() throws {
        // −6 dB with ample headroom (peak 0.6): a clean attenuation.
        let tags = ReplayGain(trackGain: -6, trackPeak: 0.6)
        let applied = calc.appliedGain(for: tags, mode: .track, preamp: 0)
        #expect(approxEqual(applied, -6))

        let baseline = try renderSine(amplitude: 0.6, globalGainDB: 0)
        let gained = try renderSine(amplitude: 0.6, globalGainDB: applied)

        let delta = Analysis.dBFS(buffer: baseline) - Analysis.dBFS(buffer: gained)
        #expect(abs(delta - 6) < 0.5, "attenuation \(delta) dB (expected ~6)")
        #expect(!Analysis.isClipped(buffer: gained), "gained output clipped")
        #expect(!Analysis.isClipped(buffer: baseline), "baseline output clipped")
    }

    @Test("anti-clip tames a +12 dB boost that would otherwise clip")
    func antiClipRenderDoesNotClip() throws {
        let hot = ReplayGain(trackGain: 12, trackPeak: 0.9)
        let applied = calc.appliedGain(for: hot, mode: .track, preamp: 0)

        // The danger is real: the raw +12 dB boost clips the same tone.
        let rawBoost = try renderSine(amplitude: 0.9, globalGainDB: 12)
        #expect(Analysis.isClipped(buffer: rawBoost), "raw +12 dB unexpectedly did not clip")

        // The computed (anti-clipped) gain brings it back to ~full scale, safe.
        let safe = try renderSine(amplitude: 0.9, globalGainDB: applied)
        #expect(Analysis.peak(buffer: safe) <= 1.0 + 1e-2, "anti-clip peak \(Analysis.peak(buffer: safe))")
        #expect(Analysis.peak(buffer: safe) < Analysis.peak(buffer: rawBoost))
    }
}
