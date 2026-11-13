@testable import AudioEngine
import AVFAudio
import Foundation
import PlayerCoreTestSupport
import Testing

/// Renders sine tones through the real parametric `AVAudioUnitEQ` in an offline
/// graph and measures what comes out.
///
/// The level cases use `source → parametricEQ → outputNode` (NOT via
/// `mainMixerNode`) so the −3 dB equal-power mono pan law never corrupts an
/// absolute measurement — the same rule ``EQGraphTests`` follows. The
/// bit-identity case deliberately DOES terminate in a mixer, because it wires the
/// real ``ProcessingNodeChain``: there the pan law is applied to both sides of an
/// A/B comparison and cancels exactly.
///
/// Boost amplitudes are 0.25 rather than the 0.9 the cut-oriented graphic-EQ
/// suite uses, so a +6 dB filter lands at 0.5 and clipping can never be what a
/// gain assertion is actually measuring.
@Suite(.serialized)
struct ParametricEQGraphTests {
    private let sampleRate = 44100.0
    private let probeAmplitude: Float = 0.25

    // MARK: - Measured filter response

    @Test("a PK filter measures its stated gain at its centre frequency")
    func peakingFilterBoostsItsCentreFrequency() throws {
        let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 6, qFactor: 1.0)
        let configuration = ParametricEQConfiguration(filters: [filter])

        let bypassed = try renderSine(frequency: filter.frequency, configuration: nil)
        let boosted = try renderSine(frequency: filter.frequency, configuration: configuration)
        let measured = Analysis.dBFS(buffer: boosted) - Analysis.dBFS(buffer: bypassed)

        #expect(abs(measured - 6) < 0.5, "measured \(measured) dB, expected +6")
        #expect(!Analysis.isClipped(buffer: boosted), "the boosted render clipped")

        // The RBJ cookbook is the independent oracle todo 7 shipped for exactly
        // this: agreeing with the textbook rules out the suite agreeing with a
        // wrong implementation of itself.
        let textbook = configuration.filterResponseDB(
            atFrequency: filter.frequency,
            sampleRate: sampleRate
        )
        #expect(abs(measured - Float(textbook)) < 0.5, "measured \(measured) dB vs RBJ \(textbook)")
    }

    /// The acceptance point is Fc/8, not one octave below Fc, for a measured
    /// reason recorded by todo 7: an `LSC 500 Hz +6 dB Q 0.70` reads +5.599 dB at
    /// 250 Hz (still on the transition slope) and +5.996 dB at 62.5 Hz (the
    /// plateau). At one octave the pass/fail would hinge on Apple's undocumented
    /// shelf slope rather than on the feature.
    @Test("an LSC shelf measures its stated gain on the plateau (Fc/8)")
    func lowShelfReachesItsGainOnThePlateau() throws {
        let filter = ParametricFilter(type: .lowShelf, frequency: 500, gainDB: 6, qFactor: 0.70)
        let configuration = ParametricEQConfiguration(filters: [filter])
        let probe = filter.frequency / 8

        let bypassed = try renderSine(frequency: probe, configuration: nil)
        let shelved = try renderSine(frequency: probe, configuration: configuration)
        let measured = Analysis.dBFS(buffer: shelved) - Analysis.dBFS(buffer: bypassed)

        #expect(abs(measured - 6) < 1.0, "measured \(measured) dB at \(probe) Hz, expected +6")
        #expect(!Analysis.isClipped(buffer: shelved), "the shelved render clipped")
        #expect(
            filter.isShelfSlopeApproximated == false,
            "Q 0.70 is inside the reference band, so this case measures the shelf, not the notice"
        )
    }

    @Test("a filter leaves frequencies far outside its band alone")
    func filterIsLocalToItsBand() throws {
        let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 12, qFactor: 4.0)
        let configuration = ParametricEQConfiguration(filters: [filter])

        let bypassed = try renderSine(frequency: 100, configuration: nil)
        let filtered = try renderSine(frequency: 100, configuration: configuration)
        let measured = Analysis.dBFS(buffer: filtered) - Analysis.dBFS(buffer: bypassed)

        #expect(abs(measured) < 0.5, "a 1 kHz Q 4 bell moved 100 Hz by \(measured) dB")
    }

    /// The pre-amp is data the gain composer owns. If a future edit ever routed
    /// it onto the node's `globalGain` as well, this render would come out 6 dB
    /// hot while every structural assertion still passed.
    @Test("the configuration's pre-amp never reaches the node's own output level")
    func preampDoesNotAlterTheRenderedLevel() throws {
        let filter = ParametricFilter(type: .peaking, frequency: 1000, gainDB: 0, qFactor: 1.0)
        let flat = ParametricEQConfiguration(filters: [filter], preampDB: 0)
        let trimmed = ParametricEQConfiguration(filters: [filter], preampDB: -6.1)

        let withoutPreamp = try renderSine(frequency: 1000, configuration: flat)
        let withPreamp = try renderSine(frequency: 1000, configuration: trimmed)
        let measured = Analysis.dBFS(buffer: withPreamp) - Analysis.dBFS(buffer: withoutPreamp)

        #expect(abs(measured) < 0.01, "the pre-amp moved the node's output by \(measured) dB")
    }

    // MARK: - Bypass is the original signal path, not an imitation of it

    @Test("clearing the stage renders bit-identically to never having installed one")
    func clearingTheStageRestoresTheBaselineSamples() throws {
        let baseline = try renderThroughChain(installThenClear: false)
        let restored = try renderThroughChain(installThenClear: true)

        #expect(baseline.frameLength == restored.frameLength)
        #expect(Analysis.peak(buffer: baseline) > 0.1, "the baseline render produced no signal")
        #expect(
            Self.firstDifferingFrame(baseline, restored) == nil,
            "a graph that once held a parametric stage no longer renders the baseline samples"
        )
    }

    // MARK: - Render helpers

    /// `source → parametricEQ → outputNode`. A `nil` configuration leaves every
    /// band bypassed, which is the reference the boost cases measure against.
    private func renderSine(
        frequency: Double,
        configuration: ParametricEQConfiguration?
    ) throws -> AVAudioPCMBuffer {
        let format = SignalGenerators.monoFormat(sampleRate: sampleRate)
        let amplitude = probeAmplitude
        let rate = sampleRate
        return try OfflineRenderHarness.render(format: format, duration: 1.0) { engine in
            let source = SignalGenerators.sine(
                frequency: frequency,
                sampleRate: rate,
                amplitude: amplitude
            )
            let node = makeParametricEQUnit()
            if let configuration {
                node.applyParametricConfiguration(configuration)
            }
            engine.attach(source)
            engine.attach(node)
            engine.connect(source, to: node, format: format)
            return node
        }
    }

    /// Drives the REAL ``ProcessingNodeChain`` so the comparison covers the
    /// production install / clear / re-wire sequence rather than a hand-built
    /// approximation of it.
    private func renderThroughChain(installThenClear: Bool) throws -> AVAudioPCMBuffer {
        let format = SignalGenerators.monoFormat(sampleRate: sampleRate)
        let amplitude = probeAmplitude
        let rate = sampleRate
        return try OfflineRenderHarness.render(format: format, duration: 0.25) { engine in
            let source = SignalGenerators.sine(frequency: 1000, sampleRate: rate, amplitude: amplitude)
            engine.attach(source)
            let chain = ProcessingNodeChain(
                equalizer: makeEQUnit(),
                balanceHost: AVAudioMixerNode(),
                balanceBox: BalanceBox(),
                spectrumProvider: SpectrumProvider()
            )
            if installThenClear {
                let node = makeParametricEQUnit()
                node.applyParametricConfiguration(Self.audibleConfiguration)
                chain.setOptionalNode(node, for: .parametric)
                chain.wire(
                    into: engine,
                    from: source,
                    terminatingAt: engine.mainMixerNode,
                    format: format
                )
                chain.setOptionalNode(nil, for: .parametric)
                chain.wire(
                    into: engine,
                    from: source,
                    terminatingAt: engine.mainMixerNode,
                    format: format
                )
                engine.detach(node)
            } else {
                chain.wire(
                    into: engine,
                    from: source,
                    terminatingAt: engine.mainMixerNode,
                    format: format
                )
            }
            return engine.mainMixerNode
        }
    }

    /// A configuration loud enough that leaving its node in the graph could not
    /// pass the bit-identity comparison by accident.
    private static let audibleConfiguration = ParametricEQConfiguration(
        filters: [ParametricFilter(type: .peaking, frequency: 1000, gainDB: 12, qFactor: 1.0)],
        preampDB: -6.1
    )

    /// The index of the first sample that differs between two renders, or `nil`
    /// when every channel matches exactly.
    private static func firstDifferingFrame(
        _ lhs: AVAudioPCMBuffer,
        _ rhs: AVAudioPCMBuffer
    ) -> Int? {
        guard
            let left = lhs.floatChannelData,
            let right = rhs.floatChannelData,
            lhs.frameLength == rhs.frameLength,
            lhs.format.channelCount == rhs.format.channelCount
        else { return 0 }
        let frames = Int(lhs.frameLength)
        for channel in 0 ..< Int(lhs.format.channelCount) {
            for frame in 0 ..< frames where left[channel][frame] != right[channel][frame] {
                return frame
            }
        }
        return nil
    }
}
