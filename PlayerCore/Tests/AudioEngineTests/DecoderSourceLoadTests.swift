@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Coverage of the decoder-OBJECT load seam: ``DecoderSource`` resolved through
/// a ``DecoderProviding`` into a concrete decoder the engine hands to its graph.
///
/// The real `SFBDecoderProvider` runs here against the committed FLAC fixture
/// (proving the seam opens real files), while the transport is the hermetic
/// ``FakePlaybackEngine`` so no default output device is needed — the real
/// `SFBAudioPlayer` hand-off is covered by ``SFBDecoderObjectLoadTests``, which
/// is hardware-gated exactly like ``SFBReloadTests``.
@MainActor
@Suite(.serialized)
struct DecoderSourceLoadTests {
    @Test("load(source:) opens a real FLAC through the decoder-object path")
    func loadSourceOpensFLAC() throws {
        let engine = FakePlaybackEngine(decoderProvider: SFBDecoderProvider())

        try engine.load(source: DecoderSource(url: AudioEngineFixtures.flac))

        #expect(engine.state == .stopped)
        #expect(engine.duration > 0)
    }

    @Test("load(source:) opens a DSD64 stream — the decoder object is what reaches the transport")
    func loadSourceOpensDSD64() throws {
        let engine = FakePlaybackEngine(decoderProvider: SFBDecoderProvider())

        try engine.load(source: DecoderSource(url: AudioEngineFixtures.dsf))

        #expect(engine.state == .stopped)
        #expect(engine.duration > 0)
    }

    @Test("a DSD128 source is refused by case, and the engine stays usable")
    func dsd128SourceIsRefusedByCase() throws {
        let engine = FakePlaybackEngine(decoderProvider: SFBDecoderProvider())

        let error = #expect(throws: DecodingError.self) {
            try engine.load(source: DecoderSource(url: AudioEngineFixtures.dsd128))
        }

        guard case .unsupportedSampleRate = error else {
            Issue.record("expected .unsupportedSampleRate, got \(String(describing: error))")
            return
        }
        try engine.load(source: DecoderSource(url: AudioEngineFixtures.dsf))
        #expect(engine.duration > 0)
    }

    @Test("a corrupt source throws DecodingError and the engine stays usable")
    func corruptSourceThrowsAndEngineSurvives() throws {
        let engine = FakePlaybackEngine(decoderProvider: SFBDecoderProvider())

        #expect(throws: DecodingError.self) {
            try engine.load(source: DecoderSource(url: AudioEngineFixtures.corruptFlac))
        }

        // The failed open left the engine ready: the URL path still works.
        try engine.load(AudioEngineFixtures.flac)
        #expect(engine.state == .stopped)
        #expect(engine.duration > 0)
    }

    @Test("a frame range plays only that region of the stream")
    func frameRangeRestrictsTheRegion() throws {
        let engine = FakePlaybackEngine(decoderProvider: SFBDecoderProvider())
        try engine.load(AudioEngineFixtures.flac)
        let whole = engine.duration

        try engine.load(source: DecoderSource(url: AudioEngineFixtures.flac, frameRange: 0 ..< 4410))

        #expect(engine.state == .stopped)
        #expect(engine.duration > 0)
        #expect(engine.duration < whole)
    }

    @Test("a backend that cannot honour a range rejects it instead of widening it")
    func unrangeableBackendRejectsARange() {
        let engine = FakePlaybackEngine(decoderProvider: UnrangeableDecoderProvider())
        let source = DecoderSource(url: URL(fileURLWithPath: "/fixtures/tone.fake"), frameRange: 0 ..< 4410)

        let error = #expect(throws: DecodingError.self) {
            try engine.load(source: source)
        }

        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
            return
        }
    }

    @Test("the URL convenience methods resolve to whole-stream sources")
    func urlMethodsAreWholeStreamSources() throws {
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 2.0))

        try engine.load(URL(fileURLWithPath: "/fixtures/tone.fake"))
        let viaURL = engine.duration
        try engine.load(source: DecoderSource(url: URL(fileURLWithPath: "/fixtures/tone.fake")))

        #expect(engine.duration == viaURL)
        #expect(abs(viaURL - 2.0) < 0.0001)
    }
}

/// A provider with no region support at all, so it inherits the default
/// ``DecoderProviding/makeDecoder(for:)`` — the branch that must REJECT a range
/// rather than quietly decode the whole stream.
private struct UnrangeableDecoderProvider: DecoderProviding {
    func makeDecoder(for url: URL) throws -> any PCMDecoding {
        try FakeDecoderProvider().makeDecoder(for: url)
    }

    static let supportedPathExtensions: Set<String> = ["fake"]
    static let supportedMIMETypes: Set<String> = []
}
