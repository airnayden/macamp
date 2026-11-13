import Accelerate
@testable import AudioEngine
import AVFAudio
import PlayerCoreTestSupport
import Testing

/// Offline proof that balance is hosted where `pan` is actually honoured.
///
/// `AVAudioMixing.pan` only takes effect on a node whose output feeds an
/// `AVAudioMixerNode`. The production graph used to set it on `mainMixerNode`,
/// which feeds the OUTPUT node — so the property was silently inert and the
/// balance slider changed nothing. The fix inserts a dedicated pan-host mixer
/// between the EQ and the main mixer.
///
/// This suite renders that exact topology offline — `source → EQ → panHost →
/// mainMixer` — and measures per-channel levels at `outputNode` (the harness
/// connects the terminal node there; assertions are NEVER taken off
/// `mainMixerNode` directly, per the harness pan-law rule).
@Suite(.serialized)
struct BalanceGraphTests {
    private static let sampleRate = 44100.0

    // MARK: - Pan behaviour (the balance maths itself)

    @Test("full-left pan silences the right channel")
    func fullLeftSilencesRight() throws {
        let rendered = try Self.renderReplica(pan: -1)
        let left = Self.channelRMS(rendered, channel: 0)
        let right = Self.channelRMS(rendered, channel: 1)
        #expect(left > 0.1, "left RMS \(left) — the tone never reached the output")
        #expect(right < left * 0.05, "right RMS \(right) vs left \(left) — pan did not attenuate the right channel")
    }

    @Test("full-right pan silences the left channel")
    func fullRightSilencesLeft() throws {
        let rendered = try Self.renderReplica(pan: 1)
        let left = Self.channelRMS(rendered, channel: 0)
        let right = Self.channelRMS(rendered, channel: 1)
        #expect(right > 0.1, "right RMS \(right) — the tone never reached the output")
        #expect(left < right * 0.05, "left RMS \(left) vs right \(right) — pan did not attenuate the left channel")
    }

    @Test("centred pan keeps both channels symmetric within 0.5 dB")
    func centreIsSymmetric() throws {
        let rendered = try Self.renderReplica(pan: 0)
        let left = Self.channelRMS(rendered, channel: 0)
        let right = Self.channelRMS(rendered, channel: 1)
        #expect(left > 0.1, "left RMS \(left)")
        #expect(right > 0.1, "right RMS \(right)")
        let imbalanceDB = abs(20 * log10(left / right))
        #expect(imbalanceDB < 0.5, "channel imbalance \(imbalanceDB) dB at centre")
    }

    @Test("a half-left pan attenuates the right channel without silencing it")
    func partialPanIsProportional() throws {
        let rendered = try Self.renderReplica(pan: -0.5)
        let left = Self.channelRMS(rendered, channel: 0)
        let right = Self.channelRMS(rendered, channel: 1)
        #expect(left > 0.1, "left RMS \(left)")
        #expect(right > 0.001, "right RMS \(right) — a half pan must not fully mute the far channel")
        #expect(right < left, "right RMS \(right) is not below left \(left)")
    }

    // MARK: - Gain staging (the inserted node must be transparent at centre)

    @Test("inserting the pan host at centre does not change the output level")
    func panHostIsTransparentAtCentre() throws {
        let baseline = try Self.renderBaselineWithoutPanHost()
        let replica = try Self.renderReplica(pan: 0)
        let baselineDB = Analysis.dBFS(buffer: baseline)
        let replicaDB = Analysis.dBFS(buffer: replica)
        let delta = abs(baselineDB - replicaDB)
        #expect(delta < 0.5, "pan host cost \(delta) dB at centre (baseline \(baselineDB), replica \(replicaDB))")
        #expect(!Analysis.isClipped(buffer: replica), "replica output clipped")
    }

    @Test("a mono source still reaches both channels through the pan host")
    func monoSourceSurvivesThePanHost() throws {
        let rendered = try Self.renderReplica(pan: 0, monoSource: true)
        let left = Self.channelRMS(rendered, channel: 0)
        let right = Self.channelRMS(rendered, channel: 1)
        #expect(left > 0.05, "mono source left RMS \(left)")
        #expect(right > 0.05, "mono source right RMS \(right)")
    }

    // MARK: - Spectrum invariance (the tap must sit PRE-pan)

    @Test("the pre-pan tap feeds the spectrum identically at every balance")
    func prePanTapIsBalanceInvariant() throws {
        let centre = try Self.renderCapturingPrePanTap(pan: 0)
        let hardLeft = try Self.renderCapturingPrePanTap(pan: -1)
        let hardRight = try Self.renderCapturingPrePanTap(pan: 1)

        #expect(centre > 0, "pre-pan tap ingested no energy at centre — the tap never fired")
        #expect(
            abs(hardLeft - centre) < centre * 0.01,
            "full-left tap energy \(hardLeft) drifted from centre \(centre)"
        )
        #expect(
            abs(hardRight - centre) < centre * 0.01,
            "full-right tap energy \(hardRight) drifted from centre \(centre)"
        )
    }

    @Test("a post-pan tap WOULD collapse at full-right — proving the tap position matters")
    func postPanTapCollapsesAtFullRight() throws {
        let centre = try Self.renderCapturingPostPanTap(pan: 0)
        let hardRight = try Self.renderCapturingPostPanTap(pan: 1)
        #expect(centre > 0, "post-pan tap ingested no energy at centre")
        #expect(
            hardRight < centre * 0.1,
            "post-pan channel-0 energy \(hardRight) vs centre \(centre) — if these matched, tap position would be moot"
        )
    }

    // MARK: - Graph builders

    /// Renders `source → EQ → panHost → mainMixer → outputNode`, the exact
    /// production topology after the fix.
    private static func renderReplica(pan: Float, monoSource: Bool = false) throws -> AVAudioPCMBuffer {
        let format = stereoFormat()
        return try OfflineRenderHarness.render(format: format, duration: 0.5) { engine in
            let source = monoSource
                ? SignalGenerators.sine(frequency: 1000, sampleRate: sampleRate, amplitude: 0.5)
                : stereoSine(frequency: 1000, amplitude: 0.5)
            let sourceFormat = monoSource
                ? SignalGenerators.monoFormat(sampleRate: sampleRate)
                : format
            let equalizer = makeEQUnit()
            let panHost = AVAudioMixerNode()
            engine.attach(source)
            engine.attach(equalizer)
            engine.attach(panHost)
            engine.connect(source, to: equalizer, format: sourceFormat)
            engine.connect(equalizer, to: panHost, format: sourceFormat)
            engine.connect(panHost, to: engine.mainMixerNode, format: sourceFormat)
            panHost.pan = pan
            return engine.mainMixerNode
        }
    }

    /// Renders `source → EQ → mainMixer → outputNode` — the topology before the
    /// fix — so the inserted pan host can be measured for gain-staging drift.
    private static func renderBaselineWithoutPanHost() throws -> AVAudioPCMBuffer {
        let format = stereoFormat()
        return try OfflineRenderHarness.render(format: format, duration: 0.5) { engine in
            let source = stereoSine(frequency: 1000, amplitude: 0.5)
            let equalizer = makeEQUnit()
            engine.attach(source)
            engine.attach(equalizer)
            engine.connect(source, to: equalizer, format: format)
            engine.connect(equalizer, to: engine.mainMixerNode, format: format)
            return engine.mainMixerNode
        }
    }

    /// Renders the replica with the production tap installed on the EQ output
    /// (PRE-pan) and returns the total energy the ``SpectrumProvider`` ingested.
    private static func renderCapturingPrePanTap(pan: Float) throws -> Float {
        try renderCapturingTap(pan: pan, tapOnEqualizer: true)
    }

    /// Renders the replica with the tap installed on the pan host's downstream
    /// mixer (POST-pan) — the placement the fix deliberately avoids.
    private static func renderCapturingPostPanTap(pan: Float) throws -> Float {
        try renderCapturingTap(pan: pan, tapOnEqualizer: false)
    }

    private static func renderCapturingTap(pan: Float, tapOnEqualizer: Bool) throws -> Float {
        let format = stereoFormat()
        let provider = SpectrumProvider()
        _ = try OfflineRenderHarness.render(format: format, duration: 0.5) { engine in
            let source = stereoSine(frequency: 1000, amplitude: 0.5)
            let equalizer = makeEQUnit()
            let panHost = AVAudioMixerNode()
            engine.attach(source)
            engine.attach(equalizer)
            engine.attach(panHost)
            engine.connect(source, to: equalizer, format: format)
            engine.connect(equalizer, to: panHost, format: format)
            engine.connect(panHost, to: engine.mainMixerNode, format: format)
            panHost.pan = pan
            SFBPlaybackEngine.installTap(on: tapOnEqualizer ? equalizer : engine.mainMixerNode, into: provider)
            return engine.mainMixerNode
        }
        return provider.latestSpectrum().reduce(0, +)
    }

    // MARK: - Signal helpers

    private static func stereoFormat() -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            fatalError("standard 44.1 kHz stereo float format is unconstructible")
        }
        return format
    }

    /// A stereo sine with identical content in both channels, so any measured
    /// L/R asymmetry can only have come from the pan host.
    private static func stereoSine(frequency: Double, amplitude: Float) -> AVAudioSourceNode {
        let phase = PhaseState()
        let increment = 2.0 * Double.pi * frequency / sampleRate
        let block: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var current = phase.value
            for frame in 0 ..< Int(frameCount) {
                let value = Float(sin(current)) * amplitude
                current += increment
                if current >= 2.0 * Double.pi { current -= 2.0 * Double.pi }
                for buffer in buffers {
                    UnsafeMutableBufferPointer<Float>(buffer)[frame] = value
                }
            }
            phase.value = current
            return noErr
        }
        return AVAudioSourceNode(format: stereoFormat(), renderBlock: block)
    }

    /// Linear RMS of ONE channel — ``Analysis/rms(buffer:)`` averages across
    /// channels, which would hide exactly the asymmetry these tests measure.
    private static func channelRMS(_ buffer: AVAudioPCMBuffer, channel: Int) -> Float {
        guard let data = buffer.floatChannelData,
              buffer.frameLength > 0,
              channel < Int(buffer.format.channelCount)
        else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(data[channel], 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }
}

/// Sine phase carried across render blocks; mutated only on the single offline
/// render thread, so `@unchecked Sendable` is sound.
private final class PhaseState: @unchecked Sendable {
    var value: Double = 0
}
