import AVFAudio
import Decoding
import Foundation
@testable import Separation
import Testing

@Suite("Separation streaming")
struct SeparationStreamingTests {
    @Test("inference starts before the decoder materializes the whole track")
    func firstPredictionPrecedesFullDecode() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let counters = StreamingCounters()
        let provider = StreamingDecoderProvider(
            source: FakeDecoderProvider(sampleRate: 44100, channelCount: 2, duration: 10),
            counters: counters
        )
        let spec = try PipelineFixture.spec(segmentSamples: 4410)
        let pipeline = try SeparationPipeline(
            decoderProvider: provider,
            separator: CoreMLSeparator(predictor: FirstPredictionProbe(counters: counters), spec: spec),
            cache: InstrumentalCache(directory: workspace.cacheDirectory),
            spec: spec, scratchDirectory: workspace.scratchDirectory, decodeBlockSize: 1024
        )
        await #expect(throws: SeparationError.inferenceFailed) {
            try await pipeline.separate(url: source)
        }
        let first = try #require(counters.firstPredictionFrames)
        #expect(first > 0)
        #expect(first <= 16384, "First prediction must use bounded input, not all 441000 source frames")
        #expect(counters.maximumRequest <= 1024)
    }

    @Test(
        "streamed conversion preserves continuity and rounded duration",
        arguments: [44100.0, 48000, 96000],
        [AVAudioChannelCount(1), 2]
    )
    func conversionIsContinuous(rate: Double, channels: AVAudioChannelCount) throws {
        let url = URL(fileURLWithPath: "stream.fake")
        let source = FakeDecoderProvider(sampleRate: rate, channelCount: channels, duration: 0.23)
        let referenceDecoder = try source.makeDecoder(for: url)
        let reference = try Resampler().normalise(referenceDecoder.decodeAll())
        let referenceChannels = try #require(reference.floatChannelData)
        for knownLength in [true, false] {
            let counters = StreamingCounters()
            let provider = StreamingDecoderProvider(source: source, counters: counters, knownLength: knownLength)
            let stream = try SeparationPCMStream(
                decoder: provider.makeDecoder(for: url),
                blockSize: 257,
                windowSize: 1000
            )
            var left: [Float] = []
            var right: [Float] = []
            while let window = try stream.next() {
                #expect(window.frameLength <= 1000)
                let data = try #require(window.floatChannelData)
                left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(window.frameLength)))
                right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: Int(window.frameLength)))
            }
            let expected = Int((Double(referenceDecoder.frameLength) * 44100 / rate).rounded())
            #expect(left.count == expected)
            #expect(right == left)
            let compared = min(left.count, Int(reference.frameLength))
            let maximumError = (0 ..< compared).map { abs(left[$0] - referenceChannels[0][$0]) }.max() ?? 0
            #expect(maximumError < 0.00001, "Stateful conversion must not restart at window boundaries")
            #expect(counters.maximumRequest <= 257)
        }
    }

    @Test(
        "integer interleaved PCM is normalized without assuming float decoder storage",
        arguments: [AVAudioChannelCount(1), 2]
    )
    func integerInterleavedInput(channels: AVAudioChannelCount) throws {
        let counters = StreamingCounters()
        let provider = StreamingDecoderProvider(
            source: FakeDecoderProvider(sampleRate: 48000, channelCount: channels, duration: 0.1),
            counters: counters, integerInterleaved: true
        )
        let decoder = try provider.makeDecoder(for: URL(fileURLWithPath: "integer.fake"))
        let stream = try SeparationPCMStream(decoder: decoder, blockSize: 257, windowSize: 1000)
        var total = 0
        var maximumError: Float = 0
        while let window = try stream.next() {
            let data = try #require(window.floatChannelData)
            for frame in 0 ..< Int(window.frameLength) {
                let expected = 0.9 * Float(sin(2 * Double.pi * 440 * Double(total + frame) / 44100))
                if total + frame > 100, total + frame < 4310 {
                    maximumError = max(maximumError, abs(data[0][frame] - expected))
                }
                #expect(data[0][frame] == data[1][frame])
            }
            total += Int(window.frameLength)
        }
        #expect(total == 4410)
        #expect(maximumError < 0.001)
        #expect(counters.maximumRequest <= 257)
    }

    @Test(
        "incremental pipeline preserves duration and monotonic progress",
        arguments: [44100.0, 48000, 96000],
        [AVAudioChannelCount(1), 2]
    )
    func pipelinePreservesDuration(rate: Double, channels: AVAudioChannelCount) async throws {
        for knownLength in [true, false] {
            let workspace = try PipelineFixture.makeWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace.root) }
            let sourceURL = try PipelineFixture.writeStubSource(in: workspace.root)
            let counters = StreamingCounters()
            let source = FakeDecoderProvider(sampleRate: rate, channelCount: channels, duration: 0.23)
            let provider = StreamingDecoderProvider(
                source: source, counters: counters, knownLength: knownLength, integerInterleaved: !knownLength
            )
            let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
            let spec = try PipelineFixture.spec(segmentSamples: 4410)
            let pipeline = PipelineFixture.pipeline(
                decoder: provider, cache: cache, spec: spec, scratch: workspace.scratchDirectory,
                predictor: ZeroVocalPredictor(counters: counters)
            )
            let result = try await pipeline.separate(url: sourceURL, progress: { counters.progress($0) })
            let file = try AVAudioFile(forReading: result)
            let inputFrames = (0.23 * rate).rounded()
            #expect(file.length == Int64((inputFrames * 44100 / rate).rounded()))
            #expect(counters.progressValues == counters.progressValues.sorted())
            #expect(counters.progressValues.allSatisfy { (0 ... 1).contains($0) })
            #expect(counters.progressValues.last == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.scratchDirectory.path).isEmpty)
        }
    }

    @Test("a late decoder failure removes partially encoded scratch and caches nothing")
    func lateDecodeFailureCleansPartialOutput() async throws {
        let workspace = try PipelineFixture.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let source = try PipelineFixture.writeStubSource(in: workspace.root)
        let counters = StreamingCounters()
        let provider = StreamingDecoderProvider(
            source: FakeDecoderProvider(channelCount: 2, duration: 1), counters: counters,
            failAfter: 16384
        )
        let cache = try InstrumentalCache(directory: workspace.cacheDirectory)
        let pipeline = try PipelineFixture.pipeline(
            decoder: provider, cache: cache, spec: PipelineFixture.spec(segmentSamples: 4410),
            scratch: workspace.scratchDirectory, predictor: ZeroVocalPredictor(counters: counters)
        )
        await #expect(throws: SeparationError.decodeFailed) { try await pipeline.separate(url: source) }
        #expect(counters.firstPredictionFrames != nil)
        #expect(await cache.entryCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.scratchDirectory.path).isEmpty)
    }
}

private final class StreamingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var decoded = 0
    private var first: Int?
    private var maximum = 0
    private var progressStorage: [Double] = []

    var firstPredictionFrames: Int? {
        lock.withLock { first }
    }

    var maximumRequest: Int {
        lock.withLock { maximum }
    }

    var progressValues: [Double] {
        lock.withLock { progressStorage }
    }

    func progress(_ value: Double) {
        lock.withLock { progressStorage.append(value) }
    }

    func didDecode(_ frames: Int, requested: Int) {
        lock.withLock {
            decoded += frames
            maximum = max(maximum, requested)
        }
    }

    func didPredict() {
        lock.withLock { if first == nil { first = decoded } }
    }
}

private struct FirstPredictionProbe: SpectrogramPredicting {
    let counters: StreamingCounters
    var availability: SeparationAvailability {
        get async { .available }
    }

    func predict(segment _: StereoSpectrogramSegment) async throws -> SegmentOutput {
        counters.didPredict()
        throw SeparationError.inferenceFailed
    }
}

private struct ZeroVocalPredictor: SpectrogramPredicting {
    let counters: StreamingCounters
    var availability: SeparationAvailability {
        get async { .available }
    }

    func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput {
        counters.didPredict()
        var left = segment.left
        var right = segment.right
        left.real = Array(repeating: 0, count: left.real.count)
        left.imag = Array(repeating: 0, count: left.imag.count)
        right.real = Array(repeating: 0, count: right.real.count)
        right.imag = Array(repeating: 0, count: right.imag.count)
        return SegmentOutput(vocalLeft: left, vocalRight: right)
    }
}

private struct StreamingDecoderProvider: DecoderProviding {
    static let supportedPathExtensions: Set<String> = ["flac"]
    static let supportedMIMETypes: Set<String> = []
    let source: FakeDecoderProvider
    let counters: StreamingCounters
    var knownLength = true
    var integerInterleaved = false
    var failAfter: Int64?

    func makeDecoder(for url: URL) throws -> any PCMDecoding {
        try StreamingDecoder(
            base: source.makeDecoder(for: url), counters: counters, knownLength: knownLength,
            integerInterleaved: integerInterleaved, failAfter: failAfter
        )
    }
}

private final class StreamingDecoder: PCMDecoding {
    let base: any PCMDecoding
    let counters: StreamingCounters
    let processingFormat: AVAudioFormat
    let knownLength: Bool
    let integerInterleaved: Bool
    let failAfter: Int64?
    var sourceFormat: AVAudioFormat? {
        base.sourceFormat
    }

    var frameLength: AVAudioFramePosition {
        knownLength ? base.frameLength : -1
    }

    var framePosition: AVAudioFramePosition {
        base.framePosition
    }

    var supportsSeeking: Bool {
        base.supportsSeeking
    }

    init(
        base: any PCMDecoding, counters: StreamingCounters, knownLength: Bool,
        integerInterleaved: Bool, failAfter: Int64?
    ) throws {
        self.base = base
        self.counters = counters
        self.knownLength = knownLength
        self.integerInterleaved = integerInterleaved
        self.failAfter = failAfter
        processingFormat = integerInterleaved ? try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: base.processingFormat.sampleRate,
            channels: base.processingFormat.channelCount, interleaved: true
        )) : base.processingFormat
    }

    func decode(into buffer: AVAudioPCMBuffer, frameLength: AVAudioFrameCount) throws -> AVAudioFrameCount {
        if let failAfter, base.framePosition >= failAfter { throw SeparationError.decodeFailed }
        let count: AVAudioFrameCount
        if integerInterleaved {
            let scratch = try #require(AVAudioPCMBuffer(pcmFormat: base.processingFormat, frameCapacity: frameLength))
            count = try base.decode(into: scratch, frameLength: frameLength)
            let input = try #require(scratch.floatChannelData)
            let output = try #require(buffer.int16ChannelData?[0])
            let channels = Int(processingFormat.channelCount)
            for frame in 0 ..< Int(count) {
                for channel in 0 ..< channels {
                    output[frame * channels + channel] = Int16(input[channel][frame] * Float(Int16.max))
                }
            }
            buffer.frameLength = count
        } else {
            count = try base.decode(into: buffer, frameLength: frameLength)
        }
        counters.didDecode(Int(count), requested: Int(frameLength))
        return count
    }

    func seek(toFrame frame: AVAudioFramePosition) throws -> AVAudioFramePosition {
        try base.seek(toFrame: frame)
    }
}
