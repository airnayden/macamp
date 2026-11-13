// SeparationPipeline quality + source-identity contract (todo 3). The pipeline stats
// the source ONCE, feeding both the cache key and the recorded SourceIdentity, threads
// the render quality into the encoder, and keeps the cache-hit short-circuit
// quality-blind: an already-cached instrumental is served regardless of the current
// quality setting (quality applies to FUTURE renders only). Driven entirely by fakes +
// a real InstrumentalCache — no Core ML model, no binary fixtures. Shares
// `PipelineFixture` with `SeparationPipelineTests`.
import AudioToolbox
import AVFAudio
import Decoding
import Foundation
import PlayerCoreTestSupport
@testable import Separation
import Testing

@Suite("SeparationPipeline quality + identity")
struct SeparationPipelineQualityTests {
    @Test("the cache key for a source is identical whether rendered at standard or lossless quality")
    func cacheKeyIsIdenticalAcrossQualities() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let spec = try PipelineFixture.spec()
        let expectedKey = try SeparationCacheKey(url: source, modelSHA: spec.modelSHA)

        let losslessCache = try InstrumentalCache(directory: workspace.root.appendingPathComponent("lossless-cache"))
        let lossless = PipelineFixture.pipeline(
            decoder: FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: 0.3),
            cache: losslessCache,
            spec: spec,
            scratch: workspace.root.appendingPathComponent("lossless-scratch"),
            quality: { .lossless }
        )
        _ = try await lossless.separate(url: source)

        let standardCache = try InstrumentalCache(directory: workspace.root.appendingPathComponent("standard-cache"))
        let standard = PipelineFixture.pipeline(
            decoder: FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: 0.3),
            cache: standardCache,
            spec: spec,
            scratch: workspace.root.appendingPathComponent("standard-scratch"),
            quality: { .standard }
        )
        _ = try await standard.separate(url: source)

        #expect(await losslessCache.contains(expectedKey))
        #expect(await standardCache.contains(expectedKey))
    }

    @Test("a render records the cache entry's sourcePath as the canonical input path")
    func recordsCanonicalSourcePath() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let spec = try PipelineFixture.spec()
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = PipelineFixture.pipeline(
            decoder: FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: 0.3),
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory
        )

        _ = try await pipeline.separate(url: source)

        let snapshot = await cache.readySnapshot()
        let record = try #require(snapshot.records.first)
        let canonicalPath = source.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(record.sourcePath == canonicalPath)
        #expect(snapshot.records.count == 1)
    }

    @Test("a cache hit after switching quality returns the cached ALAC and never runs the predictor")
    func cacheHitAfterQualitySwitchSkipsPredictor() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let spec = try PipelineFixture.spec()
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)

        let losslessPredictor = CountingSpectrogramPredictor()
        let lossless = PipelineFixture.pipeline(
            decoder: FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: 0.3),
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory,
            predictor: losslessPredictor,
            quality: { .lossless }
        )
        let first = try await lossless.separate(url: source)
        #expect(await losslessPredictor.callCount > 0)
        try expectIsALAC(first)

        let standardPredictor = CountingSpectrogramPredictor()
        let standard = PipelineFixture.pipeline(
            decoder: FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: 0.3),
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory,
            predictor: standardPredictor,
            quality: { .standard }
        )
        let second = try await standard.separate(url: source)

        #expect(second == first)
        #expect(await standardPredictor.callCount == 0)
        try expectIsALAC(second)
    }
}

// MARK: - Test doubles

/// A passthrough predictor that counts how many times it is invoked, so the cache-hit
/// path can assert ZERO inferences ran even after the quality setting changed.
private actor CountingSpectrogramPredictor: SpectrogramPredicting {
    private(set) var callCount = 0

    var availability: SeparationAvailability {
        get async { .available }
    }

    func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput {
        callCount += 1
        return SegmentOutput(vocalLeft: segment.left, vocalRight: segment.right)
    }
}

/// Asserts the file on disk is Apple Lossless — the cache serves the originally
/// rendered ALAC even after the render-quality setting changes to `.standard`.
private func expectIsALAC(_ url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
}
