// SpectrogramSegmentation — the pure (non-actor, non-Core ML) math that turns a
// mixture spectrogram into overlapping segments, reassembles per-segment vocal
// estimates with a tapered overlap-add, and performs the complex-domain
// subtraction that yields the instrumental.
//
// Kept separate from `CoreMLSeparator` so the actor's type body stays small and so
// this arithmetic is trivially unit-testable without any model. All values here
// are offline (never the audio thread). Imports only Foundation + Accelerate.
import Accelerate
import Foundation

/// Frame-domain windowing helpers for segment-by-segment separation.
enum SpectrogramSegmentation {
    /// The half-open global frame ranges of each segment tiling `frameCount`.
    ///
    /// Segments are `segmentFrames` long and advance by a stride derived from
    /// `overlap` (`0.5` ⇒ 50 % overlap). The final segment is clamped so it ends
    /// exactly at `frameCount`; every frame is covered by at least one segment.
    static func segmentRanges(frameCount: Int, segmentFrames: Int, overlap: Double) -> [Range<Int>] {
        guard frameCount > 0 else { return [] }
        let window = max(1, segmentFrames)
        if frameCount <= window { return [0 ..< frameCount] }
        let clampedOverlap = min(max(overlap, 0), 0.95)
        let stride = max(1, window - Int((Double(window) * clampedOverlap).rounded()))
        var ranges: [Range<Int>] = []
        var start = 0
        while start < frameCount {
            let end = min(start + window, frameCount)
            ranges.append(start ..< end)
            if end >= frameCount { break }
            start += stride
        }
        return ranges
    }

    /// A strictly-positive taper of length `length` (`sin(π·(i+0.5)/length)`), used
    /// to weight overlapping segment contributions. The `+0.5` offset keeps every
    /// weight above zero so the overlap-add normalisation never divides by zero.
    static func taperWeights(length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: max(length, 0)) }
        var weights = [Float](repeating: 0, count: length)
        for index in 0 ..< length {
            weights[index] = sinf(.pi * (Float(index) + 0.5) / Float(length))
        }
        return weights
    }

    /// The complex-domain subtraction `instrumental = mixture − vocal`, element-wise
    /// over `real`/`imag`. The vDSP packed-real scale factor is identical in both
    /// operands and cancels on `STFTProcessor.inverse`, so no renormalisation is
    /// needed. The result keeps the mixture's shape (so iSTFT trims to exact length).
    static func subtract(vocal: ComplexSpectrogram, from mixture: ComplexSpectrogram) -> ComplexSpectrogram {
        precondition(
            vocal.real.count == mixture.real.count && vocal.imag.count == mixture.imag.count,
            "vocal estimate must match the mixture spectrogram shape"
        )
        var real = [Float](repeating: 0, count: mixture.real.count)
        var imag = [Float](repeating: 0, count: mixture.imag.count)
        // vDSP_vsub computes C = B − A: pass vocal as A and mixture as B → mixture − vocal.
        vDSP_vsub(vocal.real, 1, mixture.real, 1, &real, 1, vDSP_Length(real.count))
        vDSP_vsub(vocal.imag, 1, mixture.imag, 1, &imag, 1, vDSP_Length(imag.count))
        return ComplexSpectrogram(
            frameCount: mixture.frameCount,
            binCount: mixture.binCount,
            real: real,
            imag: imag,
            originalSampleCount: mixture.originalSampleCount,
            configuration: mixture.configuration
        )
    }
}

/// A running, weighted overlap-add accumulator for reassembling the full-length
/// vocal estimate from per-segment predictions. Only one segment prediction is
/// ever added at a time, so the separator holds a single window in flight.
struct VocalAccumulator {
    private var real: [Float]
    private var imag: [Float]
    private var weight: [Float]
    private let frameCount: Int
    private let binCount: Int

    init(frameCount: Int, binCount: Int) {
        self.frameCount = frameCount
        self.binCount = binCount
        real = [Float](repeating: 0, count: frameCount * binCount)
        imag = [Float](repeating: 0, count: frameCount * binCount)
        weight = [Float](repeating: 0, count: frameCount)
    }

    /// Adds one segment's vocal estimate at global frame `offset`, tapered by a
    /// positive window so overlapping segments cross-fade rather than step.
    mutating func add(_ segment: ComplexSpectrogram, at offset: Int) {
        let weights = SpectrogramSegmentation.taperWeights(length: segment.frameCount)
        for localFrame in 0 ..< segment.frameCount {
            let globalFrame = offset + localFrame
            guard globalFrame < frameCount else { break }
            let segmentBase = localFrame * binCount
            let outputBase = globalFrame * binCount
            let taper = weights[localFrame]
            for bin in 0 ..< binCount {
                real[outputBase + bin] += taper * segment.real[segmentBase + bin]
                imag[outputBase + bin] += taper * segment.imag[segmentBase + bin]
            }
            weight[globalFrame] += taper
        }
    }

    /// Normalises the accumulated contributions by their summed weights and returns
    /// the full-length vocal ``ComplexSpectrogram``.
    mutating func finish(originalSampleCount: Int, configuration: STFTConfiguration) -> ComplexSpectrogram {
        for frame in 0 ..< frameCount {
            let total = weight[frame]
            guard total > 0 else { continue }
            let inverse = 1 / total
            let base = frame * binCount
            for bin in 0 ..< binCount {
                real[base + bin] *= inverse
                imag[base + bin] *= inverse
            }
        }
        return ComplexSpectrogram(
            frameCount: frameCount,
            binCount: binCount,
            real: real,
            imag: imag,
            originalSampleCount: originalSampleCount,
            configuration: configuration
        )
    }
}
