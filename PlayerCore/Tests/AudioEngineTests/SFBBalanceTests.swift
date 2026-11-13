import Accelerate
@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Real-engine coverage of the balance control on the LIVE `SFBAudioPlayer`
/// graph — the seam the offline replica in ``BalanceGraphTests`` cannot reach
/// (`OfflineRenderHarness` drives its own engine and cannot host SFB's).
///
/// `AVAudioMixing.pan` only takes effect on a node whose output feeds an
/// `AVAudioMixerNode`. Hosting it on `mainMixerNode` — which feeds the OUTPUT
/// node — made it silently inert, so the balance slider changed nothing.
///
/// The audible test needs a default output device, so — like
/// ``TapLivenessDiagnostic`` and ``SFBReloadTests`` — it is gated behind
/// `MACAMP_AUDIO_HW=1`. The structural tests run everywhere, including CI.
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter SFBBalanceTests
@MainActor
@Suite(.serialized)
struct SFBBalanceTests {
    // MARK: - Structural (headless — no audio hardware needed)

    @Test("balance is never programmed on the main mixer, whose own pan is inert")
    func mainMixerPanStaysInert() {
        let engine = SFBPlaybackEngine()
        engine.setBalance(0.7)
        #expect(
            engine.outputMixerNode.pan == 0,
            "mainMixerNode.pan is \(engine.outputMixerNode.pan) — it feeds the output node, so pan there does nothing"
        )
    }

    @Test("balance is programmed on the pan host, which is in the graph from construction")
    func balanceReachesThePanHost() {
        let engine = SFBPlaybackEngine()
        #expect(engine.isBalanceHostInstalled)
        engine.setBalance(0.7)
        #expect(engine.balanceHostPan == 0.7)
        engine.setBalance(-0.25)
        #expect(engine.balanceHostPan == -0.25)
    }

    @Test("setBalance clamps to the -1...1 range on both the stored value and the host")
    func balanceClampsAtBothEnds() {
        let engine = SFBPlaybackEngine()
        engine.setBalance(5)
        #expect(engine.balance == 1)
        #expect(engine.balanceHostPan == 1)
        engine.setBalance(-5)
        #expect(engine.balance == -1)
        #expect(engine.balanceHostPan == -1)
    }

    // MARK: - Audible (real playback through the live graph)

    @Test(
        "full-left balance silences the right channel at the graph output",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func fullLeftBalanceIsAudible() async throws {
        let levels = try await Self.measureOutputChannels(balance: -1)
        #expect(levels.left > 0.005, "left RMS \(levels.left) — no audio reached the output tap")
        #expect(
            levels.right < levels.left * 0.1,
            "right RMS \(levels.right) vs left \(levels.left) — balance had no audible effect"
        )
    }

    @Test(
        "full-right balance silences the left channel at the graph output",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func fullRightBalanceIsAudible() async throws {
        let levels = try await Self.measureOutputChannels(balance: 1)
        #expect(levels.right > 0.005, "right RMS \(levels.right) — no audio reached the output tap")
        #expect(
            levels.left < levels.right * 0.1,
            "left RMS \(levels.left) vs right \(levels.right) — balance had no audible effect"
        )
    }

    @Test(
        "centred balance leaves both channels symmetric",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func centredBalanceIsSymmetric() async throws {
        let levels = try await Self.measureOutputChannels(balance: 0)
        #expect(levels.left > 0.005, "left RMS \(levels.left)")
        #expect(levels.right > 0.005, "right RMS \(levels.right)")
        let imbalanceDB = abs(20 * log10(levels.left / levels.right))
        #expect(imbalanceDB < 1.0, "channel imbalance \(imbalanceDB) dB at centre")
    }

    // MARK: - Spectrum invariance (the tap must stay PRE-pan)

    @Test(
        "the spectrum keeps its energy at every balance — the tap sits pre-pan",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func spectrumIsBalanceInvariant() async throws {
        let centre = try await Self.measureSpectrumEnergy(balance: 0)
        let hardLeft = try await Self.measureSpectrumEnergy(balance: -1)
        let hardRight = try await Self.measureSpectrumEnergy(balance: 1)

        #expect(centre > 0, "spectrum energy \(centre) at centre — the tap never fed the ring")
        #expect(
            hardRight > centre * 0.5,
            "spectrum energy collapsed to \(hardRight) at full-right (centre \(centre)) — the tap is POST-pan"
        )
        #expect(
            hardLeft > centre * 0.5,
            "spectrum energy collapsed to \(hardLeft) at full-left (centre \(centre)) — the tap is POST-pan"
        )
        #expect(abs(hardLeft - centre) < centre * 0.15, "full-left energy \(hardLeft) vs centre \(centre)")
        #expect(abs(hardRight - centre) < centre * 0.15, "full-right energy \(hardRight) vs centre \(centre)")
    }

    // MARK: - Measurement

    /// Plays a stereo tone at `balance` and returns the total energy the
    /// production tap delivered to the ``SpectrumProvider``.
    static func measureSpectrumEnergy(balance: Float) async throws -> Float {
        let url = try makeStereoSineWAV(seconds: 2.0, frequency: 440)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = SFBPlaybackEngine()
        engine.setBalance(balance)
        try engine.load(url)
        engine.play()
        try await Task.sleep(for: .milliseconds(900))
        let energy = engine.latestSpectrum().reduce(0, +)
        engine.stop()
        return energy
    }

    /// Plays a stereo tone through the real engine at `balance` and returns the
    /// per-channel RMS measured by a temporary assertion tap on the graph output.
    ///
    /// The tap is installed AFTER `load`, because enqueueing a new format fires
    /// `reconfigureProcessingGraph`, which re-installs the production tap. A bus
    /// carries at most one tap and AVFAudio RAISES on a second install, so any
    /// incumbent is removed first — a no-op once the production tap sits pre-pan
    /// on the EQ, and a deliberate displacement on the pre-fix graph.
    static func measureOutputChannels(balance: Float) async throws -> (left: Float, right: Float) {
        let url = try makeStereoSineWAV(seconds: 2.0, frequency: 440)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = SFBPlaybackEngine()
        engine.setBalance(balance)
        try engine.load(url)

        let capture = ChannelLevelCapture()
        engine.outputMixerNode.removeTap(onBus: 0)
        engine.outputMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
            capture.accumulate(buffer)
        }
        defer { engine.outputMixerNode.removeTap(onBus: 0) }

        engine.play()
        try await Task.sleep(for: .milliseconds(900))
        engine.stop()

        return capture.channelRMS()
    }

    /// Writes a stereo 440 Hz float sine WAV with identical content in both
    /// channels, so any measured asymmetry can only have come from the pan host.
    static func makeStereoSineWAV(seconds: Double, frequency: Double) throws -> URL {
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            fatalError("unconstructible standard format")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfb-balance-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("unconstructible PCM buffer")
        }
        buffer.frameLength = frameCount
        guard let channels = buffer.floatChannelData else {
            fatalError("missing float channel data")
        }
        for frame in 0 ..< Int(frameCount) {
            let value = Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate)) * 0.5
            channels[0][frame] = value
            channels[1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }
}

/// Accumulates per-channel sums of squares from a render-thread tap.
///
/// The tap runs off-main on the real-time thread, so the counters are guarded by
/// an `NSLock` and the box is `@unchecked Sendable`. This is TEST-ONLY
/// instrumentation: locking here would violate the audio-thread invariants that
/// bind production tap closures.
final class ChannelLevelCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var sumOfSquares: [Double] = [0, 0]
    private var frames = 0

    func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let channelCount = min(Int(buffer.format.channelCount), 2)
        let frameCount = vDSP_Length(buffer.frameLength)
        var measured: [Double] = [0, 0]
        for channel in 0 ..< channelCount {
            var value: Float = 0
            vDSP_rmsqv(data[channel], 1, &value, frameCount)
            measured[channel] = Double(value) * Double(value) * Double(buffer.frameLength)
        }
        lock.lock()
        defer { lock.unlock() }
        sumOfSquares[0] += measured[0]
        sumOfSquares[1] += measured[1]
        frames += Int(buffer.frameLength)
    }

    func channelRMS() -> (left: Float, right: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0 else { return (0, 0) }
        let divisor = Double(frames)
        return (
            Float((sumOfSquares[0] / divisor).squareRoot()),
            Float((sumOfSquares[1] / divisor).squareRoot())
        )
    }
}
