// Hermetic coverage for the end-to-end separation pipeline, driven entirely by
// FakeDecoderProvider + FakeSpectrogramPredictor + a real InstrumentalCache — no
// Core ML model, no binary fixtures. Proves the assembled pipeline produces a cached
// instrumental of the exact input length, reports monotonic progress to 1.0, leaves
// no partial cache entry when cancelled mid-render, and maps a mid-stream decoder
// failure to `decodeFailed`. These run in required CI.
import AVFAudio
import Decoding
import Foundation
import PlayerCoreTestSupport
@testable import Separation
import Testing

@Suite("SeparationPipeline")
struct SeparationPipelineTests {
    @Test("caches an instrumental of the exact input length and reports monotonic progress to 1.0")
    func producesCachedInstrumentalExactDuration() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let duration = 0.5
        let decoder = FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: duration)
        let spec = try PipelineFixture.spec()
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = PipelineFixture.pipeline(
            decoder: decoder,
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory
        )
        let collector = ProgressCollector()

        let url = try await pipeline.separate(url: source, progress: { collector.append($0) })

        #expect(FileManager.default.fileExists(atPath: url.path))
        let key = try SeparationCacheKey(url: source, modelSHA: spec.modelSHA)
        #expect(await cache.contains(key))
        let progress = collector.values
        let finalValue = try #require(progress.last)
        #expect(finalValue == 1.0)
        #expect(progress == progress.sorted())
        #expect(progress.count >= 2)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition((duration * 44100).rounded()))
    }

    @Test("cancellation mid-render leaves no partial cache entry")
    func cancellationLeavesNoCacheEntry() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let decoder = FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 2, duration: 1.0)
        let spec = try PipelineFixture.spec(segmentSamples: 4410)
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = PipelineFixture.pipeline(
            decoder: decoder,
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory,
            predictor: BlockingSpectrogramPredictor()
        )
        let key = try SeparationCacheKey(url: source, modelSHA: spec.modelSHA)

        let task = Task { try await pipeline.separate(url: source) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.contains(key) == false)
        #expect(await cache.entryCount() == 0)
    }

    @Test("a decoder that fails mid-stream surfaces decodeFailed and caches nothing")
    func decoderFailureSurfacesDecodeFailed() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let spec = try PipelineFixture.spec()
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = PipelineFixture.pipeline(
            decoder: MidStreamFailProvider(framesBeforeFailure: 16384),
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory
        )
        let key = try SeparationCacheKey(url: source, modelSHA: spec.modelSHA)

        await #expect(throws: SeparationError.decodeFailed) {
            _ = try await pipeline.separate(url: source)
        }
        #expect(await cache.contains(key) == false)
        #expect(await cache.entryCount() == 0)
    }

    @Test("cancellation during the final noncooperative prediction never publishes output")
    func cancellationDuringFinalPredictionLeavesNoOutput() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let predictor = NoncooperativeFinalPredictor()
        let pipeline = try PipelineFixture.pipeline(
            decoder: FakeDecoderProvider(duration: 0.01),
            cache: cache,
            spec: PipelineFixture.spec(),
            scratch: workspace.scratchDirectory,
            predictor: predictor
        )
        let task = Task { try await pipeline.separate(url: source) }
        for _ in 0 ..< 100 {
            if await predictor.hasStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await predictor.hasStarted)
        task.cancel()
        await predictor.finish()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.entryCount() == 0)
        let scratchFiles = (try? FileManager.default.contentsOfDirectory(atPath: workspace.scratchDirectory.path)) ?? []
        #expect(scratchFiles.isEmpty)
    }

    @Test("an unavailable separator throws modelUnavailable and caches nothing")
    func unavailableSeparatorThrowsModelUnavailable() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let spec = try PipelineFixture.spec()
        let absent = workspace.root.appendingPathComponent("absent")
        let separator = CoreMLSeparator(
            modelURL: absent.appendingPathComponent("MelBandRoformer.mlmodelc"),
            manifestURL: absent.appendingPathComponent("model-manifest.json")
        )
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = SeparationPipeline(
            decoderProvider: FakeDecoderProvider(),
            separator: separator,
            cache: cache,
            spec: spec,
            scratchDirectory: workspace.scratchDirectory
        )

        #expect(await pipeline.availability == .unavailable(reason: .modelNotBundled))
        await #expect(throws: SeparationError.modelUnavailable) {
            _ = try await pipeline.separate(url: source)
        }
        #expect(await cache.entryCount() == 0)
    }

    @Test("a cancelled task queued for cache storage does not publish a file")
    func cancelledCacheStoreDoesNotPublish() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let key = try SeparationCacheKey(url: source, modelSHA: PipelineFixture.spec().modelSHA)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.store(source, for: key)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.entryCount() == 0)
        #expect(!FileManager.default
            .fileExists(atPath: workspace.cacheDirectory.appendingPathComponent("\(key.hexValue).m4a").path))
    }

    @Test("re-separating the same source reuses the cached instrumental")
    func reSeparateReusesCachedInstrumental() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let decoder = FakeDecoderProvider(frequency: 440, sampleRate: 44100, channelCount: 1, duration: 0.3)
        let spec = try PipelineFixture.spec()
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = PipelineFixture.pipeline(
            decoder: decoder,
            cache: cache,
            spec: spec,
            scratch: workspace.scratchDirectory
        )

        let first = try await pipeline.separate(url: source)
        let second = try await pipeline.separate(url: source)

        #expect(first == second)
        #expect(await cache.entryCount() == 1)
    }
}

// MARK: - Fixtures

enum PipelineFixture {
    struct Workspace {
        let root: URL
        var cacheDirectory: URL {
            root.appendingPathComponent("cache")
        }

        var scratchDirectory: URL {
            root.appendingPathComponent("scratch")
        }
    }

    static func makeWorkspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("separation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Workspace(root: root)
    }

    static func writeStubSource(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).flac")
        try Data([0x00]).write(to: url)
        return url
    }

    static func spec(segmentSamples: Int = 8820) throws -> SeparationModelSpec {
        let configuration = try STFTConfiguration(fftSize: 2048, hopLength: 441, windowLength: 2048)
        return SeparationModelSpec(
            modelVersion: "test-pipeline@fake",
            configuration: configuration,
            segmentSamples: segmentSamples,
            overlap: 0.5,
            modelSHA: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        )
    }

    static func pipeline(
        decoder: any DecoderProviding,
        cache: any InstrumentalCaching,
        spec: SeparationModelSpec,
        scratch: URL,
        predictor: any SpectrogramPredicting = FakeSpectrogramPredictor(band: 4 ..< 12),
        quality: @escaping @Sendable () -> InstrumentalRenderQuality = { .lossless }
    ) -> SeparationPipeline {
        let separator = CoreMLSeparator(predictor: predictor, spec: spec)
        return SeparationPipeline(
            decoderProvider: decoder,
            separator: separator,
            cache: cache,
            spec: spec,
            scratchDirectory: scratch,
            qualityProvider: quality
        )
    }
}

// MARK: - Test doubles

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A predictor that blocks until its surrounding task is cancelled, then throws
/// `CancellationError` — lets the cancellation test deterministically interrupt the
/// pipeline while it is inside the separation stage.
private struct BlockingSpectrogramPredictor: SpectrogramPredicting {
    var availability: SeparationAvailability {
        get async { .available }
    }

    func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return SegmentOutput(vocalLeft: segment.left, vocalRight: segment.right)
    }
}

private actor NoncooperativeFinalPredictor: SpectrogramPredicting {
    private(set) var hasStarted = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    var availability: SeparationAvailability {
        get async { .available }
    }

    func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput {
        hasStarted = true
        if !finished {
            await withCheckedContinuation { continuation = $0 }
        }
        return SegmentOutput(vocalLeft: segment.left, vocalRight: segment.right)
    }

    func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}

private struct MidStreamFailProvider: DecoderProviding {
    static let supportedPathExtensions: Set<String> = ["flac"]
    static let supportedMIMETypes: Set<String> = []
    let framesBeforeFailure: Int

    func makeDecoder(for _: URL) throws -> any PCMDecoding {
        MidStreamFailDecoder(framesBeforeFailure: framesBeforeFailure)
    }
}

/// A decoder that produces silence until `framesBeforeFailure`, then throws — the
/// mid-stream read failure the pipeline must map to `decodeFailed` (distinct from an
/// open failure).
private final class MidStreamFailDecoder: PCMDecoding {
    let processingFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat? = nil
    let frameLength: AVAudioFramePosition = 88200
    private(set) var framePosition: AVAudioFramePosition = 0
    let supportsSeeking = false
    private let framesBeforeFailure: Int

    init(framesBeforeFailure: Int) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            fatalError("standard float format is unconstructible")
        }
        processingFormat = format
        self.framesBeforeFailure = framesBeforeFailure
    }

    func decode(into buffer: AVAudioPCMBuffer, frameLength frames: AVAudioFrameCount) throws -> AVAudioFrameCount {
        if framePosition >= AVAudioFramePosition(framesBeforeFailure) {
            throw DecodingError.corruptedFile(
                url: URL(fileURLWithPath: "midstream"),
                reason: "injected mid-stream failure"
            )
        }
        let toProduce = min(Int(frames), Int(buffer.frameCapacity))
        if let data = buffer.floatChannelData {
            for channel in 0 ..< Int(buffer.format.channelCount) {
                for frame in 0 ..< toProduce {
                    data[channel][frame] = 0
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(toProduce)
        framePosition += AVAudioFramePosition(toProduce)
        return AVAudioFrameCount(toProduce)
    }

    func seek(toFrame _: AVAudioFramePosition) throws -> AVAudioFramePosition {
        framePosition
    }
}
