@testable import AudioEngine
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct FakePlaybackEngineTests {
    private let toneURL = URL(fileURLWithPath: "/fixtures/tone.fake")

    @Test("a fresh engine starts idle at position zero")
    func startsIdle() {
        let engine = FakePlaybackEngine()
        #expect(engine.state == .idle)
        #expect(engine.currentTime == 0)
        #expect(engine.duration == 0)
    }

    @Test("load transitions to stopped and computes duration from the decoder")
    func loadStopped() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 2.0))
        try engine.load(toneURL)
        #expect(engine.state == .stopped)
        #expect(abs(engine.duration - 2.0) < 0.01)
        #expect(engine.currentTime == 0)
    }

    @Test("play / pause / resume / stop drive the transport state machine")
    func transitions() throws {
        let engine = FakePlaybackEngine()
        try engine.load(toneURL)
        engine.play()
        #expect(engine.state == .playing)
        engine.pause()
        #expect(engine.state == .paused)
        engine.play()
        #expect(engine.state == .playing)
        engine.stop()
        #expect(engine.state == .stopped)
    }

    @Test("play before load is ignored (engine stays idle)")
    func playBeforeLoadIgnored() {
        let engine = FakePlaybackEngine()
        engine.play()
        #expect(engine.state == .idle)
    }

    @Test("seek clamps the position into 0 ... duration")
    func seekClamps() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 1.0))
        try engine.load(toneURL)
        engine.seek(to: 5.0)
        #expect(abs(engine.currentTime - 1.0) < 0.01)
        engine.seek(to: -3.0)
        #expect(engine.currentTime == 0)
        engine.seek(to: 0.5)
        #expect(abs(engine.currentTime - 0.5) < 0.01)
    }

    @Test("stop resets the position to the start")
    func stopResets() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 1.0))
        try engine.load(toneURL)
        engine.seek(to: 0.5)
        engine.stop()
        #expect(engine.currentTime == 0)
        #expect(engine.state == .stopped)
    }

    @Test("a corrupt source throws DecodingError and the engine survives")
    func corruptEnqueueSurvives() throws {
        let provider = FakeDecoderProvider(corruptExtensions: ["flac"])
        let engine = FakePlaybackEngine(decoderProvider: provider)
        let corrupt = URL(fileURLWithPath: "/fixtures/broken.flac")
        let error = #expect(throws: DecodingError.self) {
            try engine.enqueue(corrupt)
        }
        guard case .corruptedFile = error else {
            Issue.record("expected .corruptedFile, got \(String(describing: error))")
            return
        }
        // Still usable after a skipped decode.
        try engine.load(toneURL)
        #expect(engine.state == .stopped)
    }

    @Test("an unsupported source throws .unsupportedFormat")
    func unsupportedThrows() {
        let provider = FakeDecoderProvider(unsupportedExtensions: ["xyz"])
        let engine = FakePlaybackEngine(decoderProvider: provider)
        let error = #expect(throws: DecodingError.self) {
            try engine.load(URL(fileURLWithPath: "/fixtures/weird.xyz"))
        }
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
            return
        }
    }

    @Test("band gains are stored at their index")
    func bandGainsStored() {
        let engine = FakePlaybackEngine()
        engine.setBandGain(0, dB: -6)
        engine.setBandGain(9, dB: 6)
        #expect(engine.bandGains[0] == -6)
        #expect(engine.bandGains[9] == 6)
    }

    @Test("an out-of-range band index is ignored")
    func bandGainOutOfRange() {
        let engine = FakePlaybackEngine()
        engine.setBandGain(99, dB: 12)
        engine.setBandGain(-1, dB: 12)
        #expect(engine.bandGains.allSatisfy { $0 == 0 })
    }

    @Test("global gain is clamped into the ReplayGain range")
    func globalGainClamps() {
        let engine = FakePlaybackEngine()
        engine.setGlobalGain(100)
        #expect(engine.globalGain == 24)
        engine.setGlobalGain(-200)
        #expect(engine.globalGain == -96)
        engine.setGlobalGain(-6)
        #expect(engine.globalGain == -6)
    }

    @Test("stateDidChange fires on every transition")
    func callbackFires() throws {
        let engine = FakePlaybackEngine()
        let log = StateLog()
        engine.stateDidChange = { log.append($0) }
        try engine.load(toneURL)
        engine.play()
        engine.pause()
        engine.stop()
        #expect(log.states == [.stopped, .playing, .paused, .stopped])
    }

    @Test("reload swaps the source, seeks to the target, and keeps playing when asked")
    func reloadResumesPlaying() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 3.0))
        try engine.load(toneURL)
        engine.play()
        try engine.reload(url: toneURL, at: 1.5, resumePlaying: true)
        #expect(engine.state == .playing)
        #expect(abs(engine.currentTime - 1.5) < 0.01)
    }

    @Test("reload without resuming leaves the engine paused at the seek target")
    func reloadPausedWhenNotResuming() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 3.0))
        try engine.load(toneURL)
        engine.play()
        try engine.reload(url: toneURL, at: 2.0, resumePlaying: false)
        #expect(engine.state == .paused)
        #expect(abs(engine.currentTime - 2.0) < 0.01)
    }

    @Test("reload clamps the seek target into 0 ... duration")
    func reloadClampsSeek() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 2.0))
        try engine.load(toneURL)
        try engine.reload(url: toneURL, at: 99, resumePlaying: false)
        #expect(abs(engine.currentTime - 2.0) < 0.01)
    }

    @Test("reload with an undecodable URL throws and leaves prior state intact")
    func reloadFailureKeepsPriorState() throws {
        let provider = FakeDecoderProvider(duration: 3.0, corruptExtensions: ["flac"])
        let engine = FakePlaybackEngine(decoderProvider: provider)
        try engine.load(toneURL)
        engine.play()
        engine.seek(to: 1.0)
        engine.setGlobalGain(-6)
        engine.setBandGain(0, dB: -3)

        let corrupt = URL(fileURLWithPath: "/fixtures/broken.flac")
        let error = #expect(throws: DecodingError.self) {
            try engine.reload(url: corrupt, at: 0.25, resumePlaying: true)
        }
        guard case .corruptedFile = error else {
            Issue.record("expected .corruptedFile, got \(String(describing: error))")
            return
        }
        #expect(engine.state == .playing)
        #expect(abs(engine.currentTime - 1.0) < 0.01)
        #expect(engine.globalGain == -6)
        #expect(engine.bandGains[0] == -3)
    }
}

/// Records the states delivered to a ``PlaybackEngine/stateDidChange`` callback.
@MainActor
private final class StateLog {
    private(set) var states: [PlaybackState] = []

    func append(_ state: PlaybackState) {
        states.append(state)
    }
}
