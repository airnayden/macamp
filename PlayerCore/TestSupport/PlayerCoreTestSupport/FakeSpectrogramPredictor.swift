// FakeSpectrogramPredictor — a deterministic, file-free ``SpectrogramPredicting``
// double for exercising the chunk → predict → subtract path without Core ML.
//
// It models "vocals live in one frequency band": its estimate keeps ONLY the bins
// of a configured band (on both stereo channels) and zeroes everything else.
// Downstream, the separator's complex subtraction (instrumental = mixture − vocal)
// therefore ATTENUATES exactly that band and leaves the rest untouched — a
// behaviour a test can assert exactly. Pure Swift, in-memory only: it imports no
// Core ML and touches no disk, so it runs identically on CI, iOS, and fresh
// clones. Style mirrors the module's other fakes: an immutable value type with no
// shared mutable state (so it is trivially Sendable).
import Foundation
import Separation

/// A canned ``SpectrogramPredicting`` whose vocal estimate is the configured band.
public struct FakeSpectrogramPredictor: SpectrogramPredicting {
    /// The half-open bin range treated as "vocal" — kept in the estimate so the
    /// separator subtracts (attenuates) it out of the instrumental.
    public let band: Range<Int>
    private let configuredAvailability: SeparationAvailability

    /// - Parameters:
    ///   - band: Bin indices treated as vocal content (clamped to the input width).
    ///   - availability: What ``availability`` reports (default `.available`).
    public init(band: Range<Int>, availability: SeparationAvailability = .available) {
        self.band = band
        configuredAvailability = availability
    }

    public var availability: SeparationAvailability {
        get async { configuredAvailability }
    }

    public func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput {
        SegmentOutput(
            vocalLeft: bandOnly(segment.left),
            vocalRight: bandOnly(segment.right)
        )
    }

    private func bandOnly(_ channel: ComplexSpectrogram) -> ComplexSpectrogram {
        let binCount = channel.binCount
        let lower = max(0, band.lowerBound)
        let upper = min(binCount, band.upperBound)
        var real = [Float](repeating: 0, count: channel.real.count)
        var imag = [Float](repeating: 0, count: channel.imag.count)
        if lower < upper {
            for frame in 0 ..< channel.frameCount {
                let base = frame * binCount
                for bin in lower ..< upper {
                    real[base + bin] = channel.real[base + bin]
                    imag[base + bin] = channel.imag[base + bin]
                }
            }
        }
        return ComplexSpectrogram(
            frameCount: channel.frameCount,
            binCount: binCount,
            real: real,
            imag: imag,
            originalSampleCount: channel.originalSampleCount,
            configuration: channel.configuration
        )
    }
}
