@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// DIAGNOSTIC (opt-in, real audio hardware): proves whether the production
/// post-EQ tap actually feeds the `SpectrumProvider` ring during REAL
/// `SFBAudioPlayer` playback — the exact question synthetic UI clicks could not
/// answer reliably. The tap is installed on the EQ output (pre-pan); see
/// ``SFBBalanceTests`` for the balance-invariance guarantee that placement buys.
///
/// Gated behind `MACAMP_AUDIO_HW=1` so CI (no default output device) skips it.
/// Run locally:
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter TapLivenessDiagnostic
@MainActor
@Suite(.serialized)
struct TapLivenessDiagnostic {
    @Test(
        "real playback feeds the post-EQ tap → spectrum goes non-zero",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func tapFiresDuringRealPlayback() async throws {
        let url = try Self.makeSineWAV(seconds: 2.0, frequency: 440)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = SFBPlaybackEngine()

        let before = engine.latestSpectrum().reduce(0, +)
        #expect(before == 0, "expected silence before playback, got energy \(before)")

        try engine.load(url)
        engine.play()

        // Let the real-time render thread fill the ring (tap runs off-main).
        try await Task.sleep(for: .milliseconds(900))

        let spectrum = engine.latestSpectrum()
        let energy = spectrum.reduce(0, +)
        let peak = spectrum.max() ?? 0
        engine.stop()

        #expect(
            energy > 0,
            "spectrum energy was \(energy) (peak \(peak)) — the mainMixer tap did NOT feed the ring during real playback"
        )
    }

    /// Writes a stereo 440 Hz float sine WAV to a temp file SFB can decode.
    static func makeSineWAV(seconds: Double, frequency: Double) throws -> URL {
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            fatalError("unconstructible standard format")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tap-diag-\(UUID().uuidString).wav")
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
