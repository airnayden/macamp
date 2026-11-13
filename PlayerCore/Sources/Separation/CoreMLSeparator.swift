// CoreMLSeparator — the production `SpectrogramPredicting`: an `actor` that
// discovers the compiled Mel-Band Roformer model, verifies its manifest, and runs
// segment-by-segment stereo vocal prediction, subtracting the estimate to yield
// the instrumental.
//
// It is an `actor` because Core ML's `MLModel` is non-Sendable and must never
// cross isolation — it is created, held, and invoked entirely inside this actor.
// Discovery is an injectable seam (a `Bundle`, explicit URLs, or a swapped-in
// predictor) so tests exercise every availability outcome without a real model,
// and so NO `.mlmodelc` ever lives in the repo. Model absence, a corrupt manifest,
// a load failure, or incompatible parameters all collapse onto the single
// `.unavailable(reason:)` path used by CI, fresh clones, iOS, and App Store builds.
//
// The converted model's I/O contract (tools/separation/convert_melband_roformer.py):
// one input `mixture_spectrogram` and one output `vocal_spectrogram`, both
// (1, channels=2, freq=1025, frames, 2) float32 with real/imag LAST and a FIXED
// frame count read from the loaded model's own description (801 for the 8 s Kim
// segment). Shorter segments are zero-padded to that fixed width and sliced back.
import CoreML
import Foundation

/// Discovers, validates, and runs the on-device stem-separation model.
public actor CoreMLSeparator: SpectrogramPredicting {
    /// Default bundle resource name of the compiled model (`MelBandRoformer.mlmodelc`).
    public static let defaultModelResourceName = "MelBandRoformer"
    /// Default bundle resource name of the manifest (`model-manifest.json`).
    public static let defaultManifestResourceName = "model-manifest"
    /// Core ML feature name the model reads the mixture spectrogram from.
    static let inputFeatureName = "mixture_spectrogram"
    /// Core ML feature name the model writes the vocal estimate to.
    static let outputFeatureName = "vocal_spectrogram"

    private let modelURL: URL?
    private let manifestURL: URL?
    private let requiredModelVersion: String?
    private let predictorOverride: SpectrogramPredicting?

    private var providedSpec: SeparationModelSpec?
    private var resolvedSpec: SeparationModelSpec?
    private var resolvedAvailability: SeparationAvailability?
    private var loadedModel: MLModel?
    private var modelFrameCount = 0
    private var modelBinCount = 0

    // MARK: - Initializers

    /// Discovers the model + manifest as resources of `bundle` (production path).
    ///
    /// - Parameters:
    ///   - bundle: Where to look; defaults to `.main` (the built app).
    ///   - modelResourceName: Base name of the compiled `.mlmodelc` resource.
    ///   - manifestResourceName: Base name of the `.json` manifest resource.
    ///   - requiredModelVersion: When non-nil, the manifest's `modelVersion` must
    ///     equal this or availability resolves to `.incompatibleModel`.
    public init(
        bundle: Bundle = .main,
        modelResourceName: String = CoreMLSeparator.defaultModelResourceName,
        manifestResourceName: String = CoreMLSeparator.defaultManifestResourceName,
        requiredModelVersion: String? = nil
    ) {
        modelURL = bundle.url(forResource: modelResourceName, withExtension: "mlmodelc")
        manifestURL = bundle.url(forResource: manifestResourceName, withExtension: "json")
        self.requiredModelVersion = requiredModelVersion
        predictorOverride = nil
        providedSpec = nil
    }

    /// Discovers the model + manifest at explicit URLs (tests: missing / corrupt /
    /// incompatible fixtures without a real compiled model).
    init(modelURL: URL?, manifestURL: URL?, requiredModelVersion: String? = nil) {
        self.modelURL = modelURL
        self.manifestURL = manifestURL
        self.requiredModelVersion = requiredModelVersion
        predictorOverride = nil
        providedSpec = nil
    }

    /// Swaps in a deterministic predictor and an explicit spec, bypassing discovery
    /// entirely (tests + the gated pipeline). Availability mirrors the predictor's.
    init(predictor: SpectrogramPredicting, spec: SeparationModelSpec) {
        modelURL = nil
        manifestURL = nil
        requiredModelVersion = nil
        predictorOverride = predictor
        providedSpec = spec
        resolvedSpec = spec
    }

    // MARK: - SpectrogramPredicting

    public var availability: SeparationAvailability {
        get async {
            if let cached = resolvedAvailability { return cached }
            let outcome = await resolveAvailability()
            resolvedAvailability = outcome
            return outcome
        }
    }

    public func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput {
        if let predictorOverride {
            return try await predictorOverride.predict(segment: segment)
        }
        _ = await availability
        guard let loadedModel else {
            throw SeparationError.modelUnavailable
        }
        return try runModel(loadedModel, on: segment)
    }

    // MARK: - Separation

    /// Produces the stereo instrumental spectrograms for `mixture`: chunk into
    /// overlapping segments, predict each segment's vocal estimate (one window in
    /// flight), overlap-add the estimate per channel, then subtract it from the
    /// mixture (complex domain).
    ///
    /// - Throws: ``SeparationError/modelUnavailable`` when the model is not usable.
    public func separate(mixture: StereoSpectrogramSegment) async throws -> SegmentOutput {
        guard await availability.isAvailable, let spec = resolvedSpec else {
            throw SeparationError.modelUnavailable
        }
        let vocal = try await estimateVocal(for: mixture, spec: spec)
        return SegmentOutput(
            vocalLeft: SpectrogramSegmentation.subtract(vocal: vocal.vocalLeft, from: mixture.left),
            vocalRight: SpectrogramSegmentation.subtract(vocal: vocal.vocalRight, from: mixture.right)
        )
    }

    private func estimateVocal(
        for mixture: StereoSpectrogramSegment,
        spec: SeparationModelSpec
    ) async throws -> SegmentOutput {
        let ranges = SpectrogramSegmentation.segmentRanges(
            frameCount: mixture.left.frameCount,
            segmentFrames: spec.segmentFrames,
            overlap: spec.overlap
        )
        var leftAccumulator = VocalAccumulator(
            frameCount: mixture.left.frameCount, binCount: mixture.left.binCount
        )
        var rightAccumulator = VocalAccumulator(
            frameCount: mixture.right.frameCount, binCount: mixture.right.binCount
        )
        for range in ranges {
            try Task.checkCancellation()
            let window = StereoSpectrogramSegment(
                left: slice(mixture.left, frames: range),
                right: slice(mixture.right, frames: range)
            )
            let output = try await predict(segment: window)
            try Task.checkCancellation()
            leftAccumulator.add(output.vocalLeft, at: range.lowerBound)
            rightAccumulator.add(output.vocalRight, at: range.lowerBound)
        }
        return SegmentOutput(
            vocalLeft: leftAccumulator.finish(
                originalSampleCount: mixture.left.originalSampleCount,
                configuration: mixture.left.configuration
            ),
            vocalRight: rightAccumulator.finish(
                originalSampleCount: mixture.right.originalSampleCount,
                configuration: mixture.right.configuration
            )
        )
    }

    /// Extracts the half-open `frames` range of `channel` as a standalone segment
    /// spectrogram (one channel of the single window handed to the predictor).
    private func slice(_ channel: ComplexSpectrogram, frames: Range<Int>) -> ComplexSpectrogram {
        let binCount = channel.binCount
        let lower = frames.lowerBound * binCount
        let upper = frames.upperBound * binCount
        return ComplexSpectrogram(
            frameCount: frames.count,
            binCount: binCount,
            real: Array(channel.real[lower ..< upper]),
            imag: Array(channel.imag[lower ..< upper]),
            originalSampleCount: frames.count * channel.configuration.hopLength,
            configuration: channel.configuration
        )
    }

    // MARK: - Availability resolution

    private func resolveAvailability() async -> SeparationAvailability {
        if let predictorOverride {
            resolvedSpec = providedSpec
            return await predictorOverride.availability
        }
        guard let manifestURL, fileExists(manifestURL) else {
            return .unavailable(reason: .modelNotBundled)
        }
        guard let modelURL, fileExists(modelURL) else {
            return .unavailable(reason: .modelNotBundled)
        }
        guard let manifest = decodeManifest(at: manifestURL) else {
            return .unavailable(reason: .modelLoadFailed)
        }
        if let requiredModelVersion, manifest.modelVersion != requiredModelVersion {
            return .unavailable(reason: .incompatibleModel)
        }
        guard !manifest.modelVersion.isEmpty, let spec = try? manifest.modelSpec() else {
            return .unavailable(reason: .incompatibleModel)
        }
        // Explicitly CPU+GPU: the Apple Neural Engine compiler rejects this graph, and
        // the default `.all` spends MINUTES attempting (then failing) ANE compilation
        // on every first load. `.cpuAndGPU` loads in seconds (see the karaoke ADR).
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else {
            return .unavailable(reason: .modelLoadFailed)
        }
        guard let shape = Self.inputShape(of: model),
              shape.count == 5, shape[0] == 1, shape[1] == 2, shape[4] == 2,
              shape[2] == spec.configuration.fftSize / 2 + 1
        else {
            return .unavailable(reason: .incompatibleModel)
        }
        modelBinCount = shape[2]
        modelFrameCount = shape[3]
        loadedModel = model
        resolvedSpec = spec
        return .available
    }

    private static func inputShape(of model: MLModel) -> [Int]? {
        model.modelDescription
            .inputDescriptionsByName[inputFeatureName]?
            .multiArrayConstraint?
            .shape
            .map(\.intValue)
    }

    private func decodeManifest(at url: URL) -> SeparationManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SeparationManifest.self, from: data)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Core ML inference

    /// Runs the compiled model on one stereo segment.
    ///
    /// Marshalling: the model's fixed input is (1, 2, freq, F, 2) float32 with
    /// real/imag last and F frames (read from the model description at load).
    /// `ComplexSpectrogram` stores frames-major (`frame * binCount + bin`), so the
    /// copy transposes to the model's freq-major layout; segments shorter than F
    /// are zero-padded and the output sliced back to the actual frame count.
    private func runModel(_ model: MLModel, on segment: StereoSpectrogramSegment) throws -> SegmentOutput {
        let frames = segment.left.frameCount
        guard segment.left.binCount == modelBinCount, frames <= modelFrameCount else {
            throw SeparationError.inferenceFailed
        }
        // The pool is load-bearing for long tracks: every prediction autoreleases
        // ~26 MB of MLMultiArray/IOSurface buffers, and a multi-minute render makes
        // dozens of predictions before the caller's pool would drain — gigabytes of
        // dead buffers held across the loop without this per-prediction drain.
        return try autoreleasepool {
            let input = try multiArray(from: segment)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [Self.inputFeatureName: MLFeatureValue(multiArray: input)]
            )
            guard
                let prediction = try? model.prediction(from: provider),
                let output = prediction.featureValue(for: Self.outputFeatureName)?.multiArrayValue
            else {
                throw SeparationError.inferenceFailed
            }
            return try stereoOutput(from: output, like: segment)
        }
    }

    private func multiArray(from segment: StereoSpectrogramSegment) throws -> MLMultiArray {
        let shape = [1, 2, modelBinCount, modelFrameCount, 2].map { NSNumber(value: $0) }
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else {
            throw SeparationError.inferenceFailed
        }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        pointer.update(repeating: 0, count: array.count)
        copyChannel(segment.left, into: pointer, channel: 0)
        copyChannel(segment.right, into: pointer, channel: 1)
        return array
    }

    private func copyChannel(
        _ channel: ComplexSpectrogram, into pointer: UnsafeMutablePointer<Float>, channel index: Int
    ) {
        let channelBase = index * modelBinCount * modelFrameCount * 2
        for frame in 0 ..< channel.frameCount {
            let sourceBase = frame * channel.binCount
            for bin in 0 ..< channel.binCount {
                let destination = channelBase + (bin * modelFrameCount + frame) * 2
                pointer[destination] = channel.real[sourceBase + bin]
                pointer[destination + 1] = channel.imag[sourceBase + bin]
            }
        }
    }

    private func stereoOutput(
        from array: MLMultiArray, like segment: StereoSpectrogramSegment
    ) throws -> SegmentOutput {
        guard array.count == 2 * modelBinCount * modelFrameCount * 2, array.dataType == .float32 else {
            throw SeparationError.inferenceFailed
        }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        return SegmentOutput(
            vocalLeft: readChannel(pointer, channel: 0, like: segment.left),
            vocalRight: readChannel(pointer, channel: 1, like: segment.right)
        )
    }

    private func readChannel(
        _ pointer: UnsafeMutablePointer<Float>, channel index: Int, like reference: ComplexSpectrogram
    ) -> ComplexSpectrogram {
        let channelBase = index * modelBinCount * modelFrameCount * 2
        var real = [Float](repeating: 0, count: reference.frameCount * reference.binCount)
        var imag = [Float](repeating: 0, count: reference.frameCount * reference.binCount)
        for frame in 0 ..< reference.frameCount {
            let destinationBase = frame * reference.binCount
            for bin in 0 ..< reference.binCount {
                let source = channelBase + (bin * modelFrameCount + frame) * 2
                real[destinationBase + bin] = pointer[source]
                imag[destinationBase + bin] = pointer[source + 1]
            }
        }
        return ComplexSpectrogram(
            frameCount: reference.frameCount,
            binCount: reference.binCount,
            real: real,
            imag: imag,
            originalSampleCount: reference.originalSampleCount,
            configuration: reference.configuration
        )
    }
}
