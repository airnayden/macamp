@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Real-engine coverage of the ``PlaybackEngine/reload(url:at:resumePlaying:)``
/// source-swap seam. Loading a real decoder into the live `SFBAudioPlayer` needs
/// a default output device, so — exactly like ``TapLivenessDiagnostic`` — these
/// are gated behind `MACAMP_AUDIO_HW=1` (CI has no device; the hermetic
/// `FakePlaybackEngine` reload tests cover the contract there). Run locally:
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter SFBReloadTests
@MainActor
@Suite(.serialized)
struct SFBReloadTests {
    @Test(
        "reload swaps the source in place, resumes playing, and preserves EQ + balance",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func reloadPreservesEQAndResumes() throws {
        let first = try Self.makeSilentWAV(seconds: 2.0)
        let second = try Self.makeSilentWAV(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = SFBPlaybackEngine()
        engine.setGlobalGain(-6)
        engine.setBandGain(0, dB: -4)
        engine.setBandGain(9, dB: 5)
        engine.setBalance(0.3)
        try engine.load(first)
        engine.play()
        #expect(engine.state == .playing)

        try engine.reload(url: second, at: 0.5, resumePlaying: true)

        // reconfigureProcessingGraph re-fires, but the retained EQ + balance survive.
        #expect(engine.state == .playing)
        #expect(engine.storedGlobalGain == -6)
        #expect(engine.bandGains[0] == -4)
        #expect(engine.bandGains[9] == 5)
        #expect(abs(engine.balance - 0.3) < 0.0001)
        #expect(abs(engine.balanceHostPan - 0.3) < 0.0001)
        #expect(engine.isEQInstalled)
        engine.stop()
    }

    @Test(
        "balance survives a reload that reconfigures the graph for a new format",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func balanceSurvivesFormatChangingReload() throws {
        let first = try Self.makeSilentWAV(seconds: 2.0)
        let second = try Self.makeSilentWAV(seconds: 2.0, sampleRate: 48000)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = SFBPlaybackEngine()
        engine.setBalance(-0.6)
        try engine.load(first)
        engine.play()
        #expect(abs(engine.balanceHostPan - -0.6) < 0.0001)

        // The differing sample rate forces SFB to fire reconfigureProcessingGraph,
        // which rebuilds EQ → panHost → mainMixer and must re-apply the balance.
        try engine.reload(url: second, at: 0.5, resumePlaying: true)

        #expect(engine.state == .playing)
        #expect(abs(engine.balance - -0.6) < 0.0001)
        #expect(abs(engine.balanceHostPan - -0.6) < 0.0001, "the reconfigure pass dropped the pan")
        #expect(engine.outputMixerNode.pan == 0, "balance leaked back onto the inert main mixer")
        #expect(engine.isBalanceHostInstalled)
        engine.stop()
    }

    @Test(
        "reload without resuming leaves the engine paused with EQ intact",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func reloadPausedWhenNotResuming() throws {
        let first = try Self.makeSilentWAV(seconds: 2.0)
        let second = try Self.makeSilentWAV(seconds: 2.0)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = SFBPlaybackEngine()
        engine.setGlobalGain(-3)
        engine.setBandGain(4, dB: 8)
        try engine.load(first)
        engine.play()

        try engine.reload(url: second, at: 0.75, resumePlaying: false)

        #expect(engine.state == .paused)
        #expect(engine.storedGlobalGain == -3)
        #expect(engine.bandGains[4] == 8)
        engine.stop()
    }

    @Test(
        "reload with an undecodable URL throws DecodingError and preserves prior state",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func reloadUndecodableThrowsAndKeepsState() throws {
        let good = try Self.makeSilentWAV(seconds: 2.0)
        let bad = try Self.makeUndecodableFile()
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }
        let engine = SFBPlaybackEngine()
        engine.setGlobalGain(-6)
        engine.setBandGain(3, dB: 7)
        try engine.load(good)
        engine.play()
        #expect(engine.state == .playing)

        #expect(throws: DecodingError.self) {
            try engine.reload(url: bad, at: 0.5, resumePlaying: false)
        }

        // The failed reload left the engine exactly as it was.
        #expect(engine.state == .playing)
        #expect(engine.storedGlobalGain == -6)
        #expect(engine.bandGains[3] == 7)
        engine.stop()
    }

    // MARK: - Fixtures

    /// Writes a stereo float silent WAV to a temp file SFB can decode. A
    /// non-default `sampleRate` makes the reload cross a format boundary, which
    /// is what drives SFB's `reconfigureProcessingGraph` delegate.
    static func makeSilentWAV(seconds: Double, sampleRate: Double = 44100.0) throws -> URL {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            fatalError("unconstructible standard format")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfb-reload-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("unconstructible PCM buffer")
        }
        buffer.frameLength = frameCount // float channel data is zero-initialised → silence
        try file.write(from: buffer)
        return url
    }

    /// Writes a few garbage bytes under a `.flac` extension so SFB's decoder
    /// creation fails, exercising the ``DecodingError`` throw path.
    static func makeUndecodableFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfb-reload-bogus-\(UUID().uuidString).flac")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]).write(to: url)
        return url
    }
}
