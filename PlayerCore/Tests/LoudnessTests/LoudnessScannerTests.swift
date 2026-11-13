// LoudnessScannerTests — the per-file contract of the shipped
// ``ReplayGainScanning`` conformer.
//
// Every fixture is a dual-mono tone served through a real ``PCMDecoding`` pull
// interface, so the suite exercises the windowed decode path end to end without
// a binary fixture on disk. Mono would read 3.0103 dB low (BS.1770-4 measures
// mono as one unweighted channel), which is why the doubles are stereo.
import AVFAudio
import Foundation
import Services
import Testing

@Suite("LoudnessScannerTests")
struct LoudnessScannerTests {
    /// The peak amplitude of a −23 dBFS sine.
    static let referenceAmplitude = pow(10.0, -23.0 / 20.0)

    @Test("a −23 LUFS fixture scans to −23.0 LUFS and a +5.0 dB RG 2.0 track gain")
    func referenceToneScansToFivePointZeroGain() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/reference.flac"
        provider.register(ScanFixtures.stereoTone(dBFS: -23, seconds: 20), forPath: path)
        let scanner = LoudnessScanner(decoderProvider: provider)

        let result = try await scanner.measureLoudness(of: URL(fileURLWithPath: path))

        let lufs = try #require(result.integratedLUFS)
        #expect(abs(lufs + 23.0) < 0.1, "measured \(lufs) LUFS")
        let gain = try #require(result.trackGainDB)
        #expect(abs(gain - 5.0) < 0.1, "gain = −18 − LUFS should be +5.0, got \(gain)")
        #expect(result.blockCount == 197)
    }

    @Test("the true peak of the reference tone is recorded, within 2 % of its sample peak")
    func recordsTruePeak() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/reference.flac"
        provider.register(ScanFixtures.stereoTone(dBFS: -23, seconds: 3), forPath: path)
        let scanner = LoudnessScanner(decoderProvider: provider)

        let result = try await scanner.measureLoudness(of: URL(fileURLWithPath: path))

        let expected = Self.referenceAmplitude
        #expect(result.truePeak > 0)
        #expect(
            abs(result.truePeak - expected) < expected * 0.02,
            "true peak \(result.truePeak) vs sample peak \(expected)"
        )
    }

    @Test("2 s of digital silence spliced into the tone neither traps nor moves the reading")
    func silenceSpliceDoesNotTrap() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/spliced.flac"
        provider.register(
            ScanFixtures.stereoToneWithSilenceSplice(dBFS: -23, toneSeconds: 24, silenceSeconds: 2),
            forPath: path
        )
        let scanner = LoudnessScanner(decoderProvider: provider)

        let result = try await scanner.measureLoudness(of: URL(fileURLWithPath: path))

        let lufs = try #require(result.integratedLUFS)
        #expect(abs(lufs + 23.0) < 0.1, "measured \(lufs) LUFS")
    }

    @Test("digital silence is the nil sentinel with a zero peak and no gain")
    func silenceIsTheNilSentinel() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/silence.flac"
        let channel = LoudnessFixtures.silence(seconds: 3, sampleRate: ScanFixtures.sampleRate)
        provider.register([channel, channel], forPath: path)
        let scanner = LoudnessScanner(decoderProvider: provider)

        let result = try await scanner.measureLoudness(of: URL(fileURLWithPath: path))

        #expect(result.integratedLUFS == nil)
        #expect(result.trackGainDB == nil, "0 dB must never be substituted for the silence sentinel")
        #expect(result.truePeak == 0)
        #expect(result.blockCount > 0, "there WAS audio — it was all below the absolute gate")
    }

    @Test("the reading does not depend on the decode window size")
    func windowSizeDoesNotChangeTheReading() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/window.flac"
        provider.register(ScanFixtures.stereoTone(dBFS: -20, seconds: 3), forPath: path)
        let url = URL(fileURLWithPath: path)

        let narrow = try await LoudnessScanner(decoderProvider: provider, blockFrames: 337)
            .measureLoudness(of: url)
        let wide = try await LoudnessScanner(decoderProvider: provider, blockFrames: 32768)
            .measureLoudness(of: url)

        let narrowLUFS = try #require(narrow.integratedLUFS)
        let wideLUFS = try #require(wide.integratedLUFS)
        #expect(abs(narrowLUFS - wideLUFS) < 0.001)
        #expect(abs(narrow.truePeak - wide.truePeak) < 1e-5)
    }

    @Test("the stream is pulled in fixed windows, never in one whole-file read")
    func pullsTheStreamInFixedWindows() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/windowed.flac"
        let seconds = 2.0
        provider.register(ScanFixtures.stereoTone(dBFS: -20, seconds: seconds), forPath: path)
        let blockFrames: AVAudioFrameCount = 4096
        let scanner = LoudnessScanner(decoderProvider: provider, blockFrames: blockFrames)

        _ = try await scanner.measureLoudness(of: URL(fileURLWithPath: path))

        let frames = Int((seconds * ScanFixtures.sampleRate).rounded())
        let windows = (frames + Int(blockFrames) - 1) / Int(blockFrames)
        #expect(provider.decodeCallCount == windows + 1, "one pull per window plus the end-of-stream pull")
        #expect(provider.openCount == 1)
    }

    @Test("scan(url:) synthesizes RG 2.0 tags and leaves the album fields to the group")
    func scanSynthesizesReplayGainTags() async throws {
        let provider = PlanarBufferDecoderProvider()
        let path = "/music/tagged.flac"
        provider.register(ScanFixtures.stereoTone(dBFS: -23, seconds: 5), forPath: path)
        let scanner = LoudnessScanner(decoderProvider: provider)

        let tags = try await scanner.scan(url: URL(fileURLWithPath: path))

        #expect(tags.referenceLoudness == ReplayGainSynthesis.referenceLoudnessLUFS)
        let gain = try #require(tags.trackGain)
        #expect(abs(gain - 5.0) < 0.1)
        let peak = try #require(tags.trackPeak)
        #expect(peak > 0)
        #expect(tags.albumGain == nil)
        #expect(tags.albumPeak == nil)
    }

    @Test("an undecodable file throws instead of returning a fabricated measurement")
    func undecodableFileThrows() async throws {
        let scanner = LoudnessScanner(decoderProvider: PlanarBufferDecoderProvider())

        await #expect(throws: LoudnessScanError.self) {
            try await scanner.measureLoudness(of: URL(fileURLWithPath: "/music/absent.flac"))
        }
    }

    @Test("the RG 2.0 mapping is gain = −18 − LUFS, and absence propagates")
    func replayGainSynthesisMapping() {
        #expect(ReplayGainSynthesis.referenceLoudnessLUFS == -18.0)
        #expect(ReplayGainSynthesis.gainDB(forIntegratedLUFS: -23.0) == 5.0)
        #expect(ReplayGainSynthesis.gainDB(forIntegratedLUFS: -18.0) == 0.0)
        #expect(ReplayGainSynthesis.gainDB(forIntegratedLUFS: -8.0) == -10.0)
        #expect(ReplayGainSynthesis.gainDB(forIntegratedLUFS: nil) == nil)
        #expect(ReplayGainSynthesis.gainDB(forIntegratedLUFS: -.infinity) == nil)
    }
}
