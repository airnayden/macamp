import Decoding
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

/// Acceptance tests for the offline vDSP feature pass, driven entirely by
/// synthesised PCM — no audio fixtures on disk, so every expected value is known
/// from the generator rather than measured off a recording.
@Suite("AudioFeatureExtractorTests")
struct AudioFeatureExtractorTests {
    private static let sampleRate = 44100.0

    /// Mirrors `SpectralWindowAnalyzer.hopSize`, which is internal to `Services`.
    private static let hopSize = 512

    /// Decode calls that must have been served before the cancellation test
    /// cancels, so a pass that never started cannot masquerade as one that
    /// stopped early. Eight hops is ~93 ms of audio.
    private static let progressThreshold = 8

    @Test("A 120 BPM click track is detected within ±3 BPM")
    func clickTrackTempoIsDetected() async throws {
        let extractor = AudioFeatureExtractor(decoderProvider: Self.clickProvider(seconds: 12))
        let features = try await extractor.extractFeatures(from: Self.url("click"))
        let bpm = try #require(features.bpm)
        #expect(abs(bpm - 120) <= 3, "expected 120 ± 3 BPM, measured \(bpm)")
    }

    @Test("Tempo detection holds across the supported range", arguments: [90.0, 128.0, 174.0])
    func tempoIsDetectedAcrossTheRange(bpm: Double) async throws {
        let provider = BufferDecoderProvider(
            samples: SignalGenerators.clickTrack(bpm: bpm, duration: 12, sampleRate: Self.sampleRate),
            sampleRate: Self.sampleRate
        )
        let extractor = AudioFeatureExtractor(decoderProvider: provider)
        let features = try await extractor.extractFeatures(from: Self.url("click"))
        let measured = try #require(features.bpm)
        #expect(abs(measured - bpm) <= 3, "expected \(bpm) ± 3 BPM, measured \(measured)")
    }

    @Test("A bright tone reads brighter than a dark one")
    func brightnessSeparatesTones() async throws {
        let dark = try await Self.features(ofSineAt: 440)
        let bright = try await Self.features(ofSineAt: 8000)
        #expect(
            bright.brightness > dark.brightness,
            "8 kHz measured \(bright.brightness), 440 Hz measured \(dark.brightness)"
        )
        #expect(dark.brightness > 0)
        #expect(bright.brightness <= 1)
    }

    @Test("A full-scale sine normalizes to its own amplitude in energy")
    func energyTracksAmplitude() async throws {
        let features = try await Self.features(ofSineAt: 440)
        #expect(abs(features.energy - 0.9) < 0.02, "expected ~0.9, measured \(features.energy)")
    }

    @Test("Aperiodic broadband material reports no tempo at all")
    func broadbandNoiseYieldsNoTempo() async throws {
        let provider = BufferDecoderProvider(
            samples: SignalGenerators.whiteNoiseSamples(duration: 12, sampleRate: Self.sampleRate),
            sampleRate: Self.sampleRate
        )
        let extractor = AudioFeatureExtractor(decoderProvider: provider)
        let features = try await extractor.extractFeatures(from: Self.url("noise"))
        #expect(features.bpm == nil, "noise has no beat, measured \(String(describing: features.bpm))")
        #expect(features.energy > 0.1, "the fixture must be loud, so nil BPM is the gate and not silence")
    }

    @Test("Silence has no energy and no detectable tempo")
    func silenceYieldsNoTempo() async throws {
        let provider = FakeDecoderProvider(sampleRate: Self.sampleRate, duration: 3, amplitude: 0)
        let extractor = AudioFeatureExtractor(decoderProvider: provider)
        let features = try await extractor.extractFeatures(from: Self.url("silence"))
        #expect(features.energy < 0.01, "measured \(features.energy)")
        #expect(features.bpm == nil)
        #expect(features.brightness == 0)
    }

    @Test("Cancelling mid-file stops the pass instead of decoding to the end")
    func cancellationStopsMidFile() async throws {
        let provider = Self.clickProvider(seconds: 60)
        let fullPassCalls = provider.expectedDecodeCallCount(frameLength: Self.hopSize)
        let extractor = AudioFeatureExtractor(decoderProvider: provider)
        let task = Task { try await extractor.extractFeatures(from: Self.url("long")) }

        var observed = 0
        var polls = 0
        while observed < Self.progressThreshold, polls < 500 {
            try await Task.sleep(for: .milliseconds(2))
            observed = provider.decodeCallCount
            polls += 1
        }
        #expect(observed >= Self.progressThreshold, "the pass never began decoding")
        task.cancel()

        var thrown: (any Error)?
        do {
            _ = try await task.value
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError, "expected CancellationError, got \(String(describing: thrown))")
        #expect(
            provider.decodeCallCount < fullPassCalls,
            "decoded \(provider.decodeCallCount) of \(fullPassCalls) windows despite cancellation"
        )
    }

    @Test("Undecodable input throws a typed error rather than zero features")
    func undecodableInputThrows() async throws {
        let extractor = AudioFeatureExtractor(decoderProvider: FakeDecoderProvider(corruptExtensions: ["fake"]))
        let url = Self.url("broken")

        var thrown: (any Error)?
        do {
            _ = try await extractor.extractFeatures(from: url)
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? AudioFeatureError)
        guard case let .decodeFailed(failedURL, reason) = error else {
            Issue.record("expected .decodeFailed, got \(error)")
            return
        }
        #expect(failedURL == url)
        #expect(!reason.isEmpty)
    }

    @Test("A reused extractor answers identically on the second pass")
    func pooledScratchIsResetBetweenPasses() async throws {
        let extractor = AudioFeatureExtractor(decoderProvider: Self.clickProvider(seconds: 12))
        let first = try await extractor.extractFeatures(from: Self.url("click"))
        let second = try await extractor.extractFeatures(from: Self.url("click"))
        #expect(first == second)
    }

    // MARK: - Fixtures

    private static func clickProvider(seconds: Double) -> BufferDecoderProvider {
        BufferDecoderProvider(
            samples: SignalGenerators.clickTrack(bpm: 120, duration: seconds, sampleRate: sampleRate),
            sampleRate: sampleRate
        )
    }

    private static func features(ofSineAt frequency: Double) async throws -> AudioFeatureResult {
        let provider = FakeDecoderProvider(frequency: frequency, sampleRate: sampleRate, duration: 3)
        let extractor = AudioFeatureExtractor(decoderProvider: provider)
        return try await extractor.extractFeatures(from: url("tone"))
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/macamp-audio-feature-\(name).fake")
    }
}
