// SeparationPipeline — the production ``StemSeparating``: turns a song into a
// cached instrumental, offline.
//
// It assembles the already-built stages into one end-to-end render:
//
//   decode (windowed pulls, NOT decodeAll)
//     → stateful resample to 44.1 kHz / 2ch    (SeparationPCMStream)
//     → per-segment STFT                        (STFTProcessor.forward)
//     → vocal removal                           (CoreMLSeparator.separate)
//     → per-segment iSTFT + exact-length trim   (STFTProcessor.inverse)
//     → ALAC or AAC .m4a                        (InstrumentalWriter)
//     → content-addressed cache                 (InstrumentalCache.store)
//
// Memory: source decode, sample-rate conversion, model windows and encoding are
// bounded by decodeBlockSize and segmentSamples. The converter keeps one output
// window of lookahead to preserve exact duration at EOF; no stage accumulates
// full-track PCM or spectrogram arrays.
//
// Concurrency: `separate` checks `Task.checkCancellation()` between segments, so a
// cancelled render throws `CancellationError` before anything is written to the cache
// (the instrumental is only published on the final `store`). Progress is reported
// `0...1`, monotonically, ending at exactly `1.0`, and is equality-guarded so a
// stalled fraction never fires a redundant callback.
//
// OFFLINE (pre-render) processing — NEVER call it on the audio thread. PlayerCore
// portability: imports only AVFAudio + Foundation + the Decoding module.
import AVFAudio
import Decoding
import Foundation

/// The production ``StemSeparating`` that renders and caches a track's instrumental.
public struct SeparationPipeline: StemSeparating {
    private let decoderProvider: any DecoderProviding
    private let separator: CoreMLSeparator
    private let cache: any InstrumentalCaching
    private let spec: SeparationModelSpec
    private let scratchDirectory: URL
    private let decodeBlockSize: AVAudioFrameCount
    private let qualityProvider: @Sendable () -> InstrumentalRenderQuality

    /// Assembles a pipeline from its stages.
    ///
    /// The converter, incremental encoder and STFT stages are constructed
    /// internally — only the fakeable seams (decoder / separator /
    /// cache) and the run configuration are injected.
    ///
    /// - Parameters:
    ///   - decoderProvider: Opens the source file (windowed PCM pulls).
    ///   - separator: The vocal-removing separator. Its `availability` gates the
    ///     whole pipeline; for tests, build it with a `FakeSpectrogramPredictor` via
    ///     `CoreMLSeparator(predictor:spec:)`.
    ///   - cache: Where rendered instrumentals are stored and looked up.
    ///   - spec: The model run spec (STFT config, segment length, model SHA). In
    ///     production, resolve it from the bundled manifest with
    ///     ``resolveModelSpec(bundle:manifestResourceName:)``.
    ///   - scratchDirectory: Where the instrumental is written before being handed to
    ///     the cache (created on demand; the temp file is always removed).
    ///   - decodeBlockSize: Frames pulled from the decoder per window.
    ///   - qualityProvider: Supplies the encode tier for each render, read once per
    ///     `separate` when the instrumental is written. Defaults to `.lossless`; the
    ///     composition root passes a closure reading the user's setting. Only future
    ///     renders honour a change — a cache hit serves its existing file regardless.
    public init(
        decoderProvider: any DecoderProviding,
        separator: CoreMLSeparator,
        cache: any InstrumentalCaching,
        spec: SeparationModelSpec,
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        decodeBlockSize: AVAudioFrameCount = 16384,
        qualityProvider: @escaping @Sendable () -> InstrumentalRenderQuality = { .lossless }
    ) {
        self.decoderProvider = decoderProvider
        self.separator = separator
        self.cache = cache
        self.spec = spec
        self.scratchDirectory = scratchDirectory
        self.decodeBlockSize = decodeBlockSize
        self.qualityProvider = qualityProvider
    }

    // MARK: - StemSeparating

    public var availability: SeparationAvailability {
        get async { await separator.availability }
    }

    public func separate(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard await availability.isAvailable else {
            throw SeparationError.modelUnavailable
        }
        let identity = try makeSourceIdentity(for: url)
        let key = SeparationCacheKey(identity: identity, modelSHA: spec.modelSHA)
        if let cached = await cache.cachedInstrumental(for: key) {
            progress(1.0)
            return cached
        }
        try Task.checkCancellation()
        let reporter = ProgressReporter(progress)
        let decoder = try await openDecoder(url)
        let stream = try SeparationPCMStream(
            decoder: decoder, blockSize: decodeBlockSize, windowSize: max(spec.segmentSamples, 1)
        )
        let cachedURL = try await renderAndStore(stream, key: key, identity: identity, reporter: reporter)
        reporter.report(1.0)
        return cachedURL
    }

    // MARK: - Production spec resolution

    /// Resolves the model run spec from a bundled `model-manifest.json`, or `nil` when
    /// it is absent or invalid (⇒ the pipeline's `availability` will be `.unavailable`
    /// and `separate` throws `.modelUnavailable`). Lets a composition root build the
    /// `spec` the initializer needs without reaching into the internal manifest type.
    public static func resolveModelSpec(
        bundle: Bundle = .main,
        manifestResourceName: String = CoreMLSeparator.defaultManifestResourceName
    ) -> SeparationModelSpec? {
        guard
            let url = bundle.url(forResource: manifestResourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(SeparationManifest.self, from: data),
            let spec = try? manifest.modelSpec()
        else {
            return nil
        }
        return spec
    }

    // MARK: - Stages

    /// Stats the source ONCE into its ``SourceIdentity`` (canonical path ⊕ size ⊕
    /// mtime) — the same fingerprint that keys the cache and is recorded on the
    /// stored entry. A file that cannot be stat-ed surfaces as
    /// ``SeparationError/decodeFailed``.
    private func makeSourceIdentity(for url: URL) throws -> SourceIdentity {
        do {
            return try SeparationCacheKey.sourceIdentity(for: url)
        } catch {
            throw SeparationError.decodeFailed
        }
    }

    /// Only codec opening is gated; subsequent pulls remain task-confined.
    private func openDecoder(_ url: URL) async throws -> any PCMDecoding {
        do {
            return try await DecoderOpenGate.shared.open(url, with: decoderProvider)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SeparationError.decodeFailed
        }
    }

    private func renderAndStore(
        _ stream: SeparationPCMStream, key: SeparationCacheKey,
        identity: SourceIdentity, reporter: ProgressReporter
    ) async throws -> URL {
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        } catch {
            throw SeparationError.encodeFailed
        }
        let scratchURL = scratchDirectory.appendingPathComponent("macamp-separation-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: scratchURL) }
        let quality = qualityProvider()
        var writer: InstrumentalWriteStream?
        let processor = STFTProcessor(configuration: spec.configuration)
        while let window = try stream.next() {
            try Task.checkCancellation()
            guard let channels = window.floatChannelData else { throw SeparationError.decodeFailed }
            let count = Int(window.frameLength)
            let segment = try await separateSegment(
                left: Array(UnsafeBufferPointer(start: channels[0], count: count)),
                right: Array(UnsafeBufferPointer(start: channels[1], count: count)),
                processor: processor
            )
            try Task.checkCancellation()
            if writer == nil { writer = try InstrumentalWriteStream(to: scratchURL, quality: quality) }
            try writer?.append(makeOutputBuffer(left: segment.left, right: segment.right))
            let completed = Double(stream.emittedFrames)
            let estimate = stream.estimatedOutputFrames ?? (completed + Double(max(spec.segmentSamples, 1)))
            reporter.report(min(0.99, completed / max(estimate, 1)))
        }
        try Task.checkCancellation()
        guard let writer else { throw SeparationError.decodeFailed }
        try writer.finish()
        try Task.checkCancellation()
        return try await cache.store(scratchURL, for: key, identity: identity)
    }

    /// One stereo segment: STFT both channels → one stereo vocal-removal prediction
    /// → iSTFT both (trimmed to the segment's exact length). An iSTFT config
    /// mismatch maps to `.inferenceFailed`.
    private func separateSegment(
        left: [Float], right: [Float], processor: STFTProcessor
    ) async throws -> (left: [Float], right: [Float]) {
        let mixture = StereoSpectrogramSegment(
            left: processor.forward(left),
            right: processor.forward(right)
        )
        let instrumental = try await separator.separate(mixture: mixture)
        do {
            return try (
                left: processor.inverse(instrumental.vocalLeft),
                right: processor.inverse(instrumental.vocalRight)
            )
        } catch {
            throw SeparationError.inferenceFailed
        }
    }

    /// Packs the two reconstructed channels into an ``InstrumentalWriter``-format
    /// buffer (deinterleaved float32, 44.1 kHz stereo), preserving the exact length.
    private func makeOutputBuffer(left: [Float], right: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = InstrumentalWriter.processingFormat else {
            throw SeparationError.encodeFailed
        }
        let frames = AVAudioFrameCount(left.count)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)),
            let channelData = buffer.floatChannelData
        else {
            throw SeparationError.encodeFailed
        }
        buffer.frameLength = frames
        copy(left, into: channelData[0])
        copy(right, into: channelData[1])
        return buffer
    }

    private func copy(_ samples: [Float], into destination: UnsafeMutablePointer<Float>) {
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: samples.count)
        }
    }
}

// MARK: - Progress

/// Fires a `0...1` progress sink only when the value actually changes (equality-
/// guarded — UI-perf rule 3), tracking the last reported value across the pipeline's
/// stages. Used within a single task, so it needs no synchronisation.
private final class ProgressReporter {
    private let sink: @Sendable (Double) -> Void
    private var last = -1.0

    init(_ sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    /// Reports `value` (clamped to `0...1`), suppressing an unchanged repeat.
    func report(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        guard clamped > last else { return }
        last = clamped
        sink(clamped)
    }
}
