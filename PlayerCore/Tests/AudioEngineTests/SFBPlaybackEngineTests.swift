@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Headless coverage of the production engine. Constructing an `SFBAudioPlayer`
/// and modifying its processing graph is safe WITHOUT starting the engine, so
/// these run with no audio hardware (the player owns lifecycle; we never call
/// `engine.start()`).
@MainActor
@Suite(.serialized)
struct SFBPlaybackEngineTests {
    @Test("constructs headless with the EQ inserted into the processing graph")
    func eqInsertedHeadless() {
        let engine = SFBPlaybackEngine()
        #expect(engine.isEQInstalled)
    }

    @Test("a corrupt enqueue is caught and skipped; the engine stays usable")
    func corruptEnqueueSkipped() {
        let provider = FakeDecoderProvider(corruptExtensions: ["flac"])
        let engine = SFBPlaybackEngine(decoderProvider: provider)
        let corrupt = URL(fileURLWithPath: "/fixtures/broken.flac")
        let error = #expect(throws: DecodingError.self) {
            try engine.enqueue(corrupt)
        }
        guard case .corruptedFile = error else {
            Issue.record("expected .corruptedFile, got \(String(describing: error))")
            return
        }
        // Still usable after a skipped decode.
        #expect(engine.isEQInstalled)
        #expect(engine.latestSpectrum().count == 128)
    }

    @Test("latestSpectrum returns 128 finite, non-negative bands with no audio")
    func latestSpectrumSafe() {
        let engine = SFBPlaybackEngine()
        let spectrum = engine.latestSpectrum()
        #expect(spectrum.count == 128)
        #expect(spectrum.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    @Test("setGlobalGain clamps and stores the ReplayGain trim")
    func globalGainClampsAndStores() {
        let engine = SFBPlaybackEngine()
        engine.setGlobalGain(100)
        #expect(engine.storedGlobalGain == 24)
        engine.setGlobalGain(-200)
        #expect(engine.storedGlobalGain == -96)
        engine.setGlobalGain(-3.5)
        #expect(engine.storedGlobalGain == -3.5)
    }

    @Test("setBandGain on an out-of-range index is ignored safely")
    func bandGainOutOfRangeIgnored() {
        let engine = SFBPlaybackEngine()
        engine.setBandGain(999, dB: 12) // must not trap
        engine.setBandGain(0, dB: -6)
        #expect(engine.isEQInstalled)
    }

    /// Regression lock on the visualizer's delivery latency. Core Audio fills a
    /// whole tap buffer before the closure runs, so this constant IS the floor on
    /// spike-to-pixels lag: 4096 frames is ~93 ms at 44.1 kHz, 1024 is ~23 ms.
    /// Re-aligning it with the analyzer's 4096-sample FFT read would silently
    /// restore the lag.
    @Test("the tap requests 1024-frame buffers — the visualizer latency floor")
    func tapRequestsLowLatencyBuffers() {
        #expect(SFBPlaybackEngine.tapBufferSize == 1024)
    }

    @Test("the tap request stays well inside the ring so no delivery is dropped")
    func tapBufferFitsTheRing() {
        #expect(SFBPlaybackEngine.tapBufferSize > 0)
        #expect(SFBPlaybackEngine.tapBufferSize < AVAudioFrameCount(16384))
    }
}
