// HarnessBaselineTests — proves the Swift Testing + offline-render foundation works.
//
// This baseline suite exercises the whole TDD stack end to end:
//   * Swift Testing (`import Testing`, `#expect`, `#require`, `@Test(arguments:)`)
//   * The offline render harness (no audio hardware)
//   * The spectral / level analysis helpers
//   * The `.serialized` trait that all real engine suites must use.
//
// Swift Testing is built into the Swift 6 toolchain — it is NOT an SPM dependency.
import AVFAudio
import PlayerCoreTestSupport
import Testing

@Suite("Harness baseline")
struct HarnessBaselineTests {
    static let sampleRate = 44100.0
    static let fftSize = 4096

    /// Renders a 1 kHz sine through a unity-gain graph and asserts the FFT peak
    /// bin lands where theory predicts (±1 bin).
    @Test("1 kHz sine round-trips to the expected FFT bin")
    func sineRoundTrip() throws {
        // `#require` proves the require macro compiles and unwraps.
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        )

        let buffer = try OfflineRenderHarness.render(format: format, duration: 1.0) { engine in
            // Source -> explicit unity-gain node -> (harness connects to mainMixer).
            let source = SignalGenerators.sine(frequency: 1000, sampleRate: Self.sampleRate)
            engine.attach(source)
            let gain = AVAudioMixerNode() // proof-of-concept gain node
            engine.attach(gain)
            gain.outputVolume = 1.0 // unity gain
            engine.connect(source, to: gain, format: format)
            return gain
        }

        let result = Analysis.peakBin(buffer: buffer, fftSize: Self.fftSize)
        let expectedBin = Int((1000.0 * Double(Self.fftSize) / Self.sampleRate).rounded())

        #expect(
            abs(result.bin - expectedBin) <= 1,
            "peak bin \(result.bin) should be within ±1 of \(expectedBin) (\(result.frequency) Hz)"
        )
        #expect(!Analysis.isClipped(buffer: buffer), "unity-gain 0.9-amplitude sine must not clip")
        #expect(Analysis.duration(buffer: buffer) > 0.99, "should have rendered ~1 s")
    }

    /// Proves `@Test(arguments:)` parameterized tests work across frequencies.
    @Test("Parameterized tone frequencies land on the right bin", arguments: [440.0, 1000.0, 4000.0])
    func parameterizedFrequencies(frequency: Double) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        )
        let buffer = try OfflineRenderHarness.render(format: format, duration: 0.5) { engine in
            let source = SignalGenerators.sine(frequency: frequency, sampleRate: Self.sampleRate)
            engine.attach(source)
            return source
        }
        let result = Analysis.peakBin(buffer: buffer, fftSize: Self.fftSize)
        let expectedBin = Int((frequency * Double(Self.fftSize) / Self.sampleRate).rounded())
        #expect(abs(result.bin - expectedBin) <= 2, "f=\(frequency): bin \(result.bin) vs \(expectedBin)")
    }

    /// Silence must read as near-zero RMS and report no discontinuity.
    @Test("Silence is silent and not a discontinuity")
    func silenceIsSilent() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        )
        let buffer = try OfflineRenderHarness.render(format: format, duration: 0.25) { engine in
            let source = SignalGenerators.silence(sampleRate: Self.sampleRate)
            engine.attach(source)
            return source
        }
        #expect(Analysis.rms(buffer: buffer) < 1e-5)
        #expect(!Analysis.hasDiscontinuity(buffer: buffer))
    }

    /// Two concatenated tones must contain no inserted silence gap (gapless).
    @Test("Concatenated tones are gapless")
    func concatenatedTonesAreGapless() {
        let buffer = SignalGenerators.concatenated(
            toneA: (freq: 440, duration: 0.2),
            toneB: (freq: 880, duration: 0.2),
            sampleRate: Self.sampleRate
        )
        #expect(!Analysis.hasDiscontinuity(buffer: buffer), "back-to-back tones must be gapless")
        #expect(Analysis.duration(buffer: buffer) > 0.39)
    }

    /// White noise has broadband energy (non-trivial RMS) but stays below clip.
    @Test("White noise has energy and does not clip")
    func whiteNoiseHasEnergy() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        )
        let buffer = try OfflineRenderHarness.render(format: format, duration: 0.25) { engine in
            let source = SignalGenerators.whiteNoise(sampleRate: Self.sampleRate, amplitude: 0.5)
            engine.attach(source)
            return source
        }
        #expect(Analysis.rms(buffer: buffer) > 0.05)
        #expect(!Analysis.isClipped(buffer: buffer))
    }
}

/// Proves the `.serialized` trait compiles and runs. Real `AVAudioEngine` suites
/// MUST adopt `.serialized` so parallel tests never collide on shared engine state.
@Suite("Serialized engine baseline", .serialized)
struct SerializedEngineTests {
    @Test("Offline engine renders under the serialized trait")
    func enginesRenderSerially() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try OfflineRenderHarness.render(format: format, duration: 0.1) { engine in
            let source = SignalGenerators.sine(frequency: 1000, sampleRate: 44100)
            engine.attach(source)
            return source
        }
        #expect(buffer.frameLength > 0)
    }

    @Test("A second serialized engine render also succeeds")
    func secondSerialRender() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try OfflineRenderHarness.render(format: format, duration: 0.1) { engine in
            let source = SignalGenerators.silence(sampleRate: 48000)
            engine.attach(source)
            return source
        }
        #expect(buffer.frameLength > 0)
    }
}
