// SeparationManifest — the on-disk `model-manifest.json` shipped alongside the
// compiled `MelBandRoformer.mlmodelc`, plus the resolved `SeparationModelSpec` the
// separator runs against.
//
// The manifest is the single source of truth for the model's audio parameters
// (STFT shape, segment length, overlap) — the pipeline NEVER hardcodes them. The
// `sha256` is the SOURCE-package hash recorded at conversion time; it is used only
// for cache-key versioning and is never compared against the compiled bundle. This
// file imports only Foundation and MUST NOT import AppKit/UIKit.
import Foundation

/// The decoded `model-manifest.json` (nine keys, established by the conversion
/// pipeline). Decodes directly from the committed `model-manifest.sample.json`.
struct SeparationManifest: Decodable, Equatable {
    /// Compatibility token, e.g. `"kj-melband-roformer-vocals@25f44ffb55ee"`.
    let modelVersion: String
    /// SHA-256 of the SOURCE package (cache-key versioning ONLY; never hashed against the bundle).
    let sha256: String
    /// Native sample rate the model expects (Hz).
    let sampleRate: Int
    /// Native channel count the model expects.
    let channels: Int
    /// FFT length in samples (maps to ``STFTConfiguration/fftSize``).
    let nFFT: Int
    /// STFT hop in samples.
    let hopLength: Int
    /// Hann window length in samples.
    let windowLength: Int
    /// Model input window length in samples (the chunk size for inference).
    let segmentSamples: Int
    /// Fractional overlap between consecutive segments (`0.5` ⇒ 50 %).
    let overlap: Double

    /// The STFT parameters as the shared, validated ``STFTConfiguration``. Throws
    /// ``STFTError`` when the manifest declares parameters the processor rejects
    /// (non-power-of-two FFT, hop greater than window, …) — the separator maps that
    /// throw onto ``SeparationUnavailableReason/incompatibleModel``.
    func stftConfiguration() throws -> STFTConfiguration {
        try STFTConfiguration(fftSize: nFFT, hopLength: hopLength, windowLength: windowLength)
    }

    /// Resolves the full run spec, validating the STFT parameters in the process.
    func modelSpec() throws -> SeparationModelSpec {
        try SeparationModelSpec(
            modelVersion: modelVersion,
            configuration: stftConfiguration(),
            segmentSamples: segmentSamples,
            overlap: overlap,
            modelSHA: sha256
        )
    }
}

/// The validated parameters the separator runs against, resolved from a manifest
/// (production) or supplied directly (tests with an injected predictor).
public struct SeparationModelSpec: Sendable, Equatable {
    /// Compatibility token from the manifest.
    public let modelVersion: String
    /// The STFT transform shape (already validated).
    public let configuration: STFTConfiguration
    /// Model input window length in samples.
    public let segmentSamples: Int
    /// Fractional overlap between consecutive segments.
    public let overlap: Double
    /// SOURCE-package SHA-256 (cache-key versioning only).
    public let modelSHA: String

    public init(
        modelVersion: String,
        configuration: STFTConfiguration,
        segmentSamples: Int,
        overlap: Double,
        modelSHA: String
    ) {
        self.modelVersion = modelVersion
        self.configuration = configuration
        self.segmentSamples = segmentSamples
        self.overlap = overlap
        self.modelSHA = modelSHA
    }

    /// Segment length expressed in STFT frames — the granularity the separator
    /// chunks a spectrogram into. The `+ 1` is the center-padded STFT framing
    /// (`n / hop + 1`) and matches the converted model's fixed input width; without
    /// it a full segment's 801 frames exceed an 800-frame window by ONE frame and
    /// split into TWO overlapping predictions — doubling inference cost for nothing.
    var segmentFrames: Int {
        max(1, segmentSamples / configuration.hopLength + 1)
    }
}
