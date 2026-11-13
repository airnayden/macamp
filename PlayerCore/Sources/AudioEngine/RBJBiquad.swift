// RBJBiquad — a reference implementation of the RBJ "Audio EQ Cookbook" biquads.
//
// This is the INDEPENDENT ORACLE for the parametric EQ: it computes what a
// `ParametricFilter` is *supposed* to do, from the textbook coefficient
// formulas, so a test can assert the shipped path against it instead of against
// itself. Todo 19's offline-render acceptance cases measure `AVAudioUnitEQ`'s
// actual output and compare it to this model.
//
// It is NOT a runtime DSP kernel: nothing here is called from the render thread
// or the tap, nothing is pre-allocated, and there is no `process(_:)`. The
// magnitude evaluation is a pure function of the coefficients.
//
// Reference: Robert Bristow-Johnson, "Cookbook formulae for audio equalizer
// biquad filter coefficients" (the peakingEQ / lowShelf / highShelf sections).
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A normalised second-order IIR section, `a0` divided out.
///
/// The transfer function is
/// `H(z) = (numer0 + numer1·z⁻¹ + numer2·z⁻²) / (1 + denom1·z⁻¹ + denom2·z⁻²)`.
///
/// Coefficients are spelled out rather than stored as `b0…a2` because SwiftLint's
/// `identifier_name` rule requires three characters.
public struct RBJBiquad: Sendable, Equatable {
    /// Feed-forward coefficient b0/a0.
    public let numer0: Double
    /// Feed-forward coefficient b1/a0.
    public let numer1: Double
    /// Feed-forward coefficient b2/a0.
    public let numer2: Double
    /// Feed-back coefficient a1/a0.
    public let denom1: Double
    /// Feed-back coefficient a2/a0.
    public let denom2: Double

    public init(numer0: Double, numer1: Double, numer2: Double, denom1: Double, denom2: Double) {
        self.numer0 = numer0
        self.numer1 = numer1
        self.numer2 = numer2
        self.denom1 = denom1
        self.denom2 = denom2
    }
}

// MARK: - Design

public extension RBJBiquad {
    /// Designs the cookbook biquad for `filter` at `sampleRate`.
    ///
    /// Shared cookbook intermediates:
    /// `A = 10^(gain/40)`, `ω₀ = 2π·f₀/Fs`, `α = sin(ω₀)/(2Q)`.
    static func make(for filter: ParametricFilter, sampleRate: Double) -> RBJBiquad {
        let ampl = pow(10, filter.gainDB / 40)
        let omega = 2 * Double.pi * filter.frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * max(filter.qFactor, .leastNormalMagnitude))

        switch filter.type {
        case .peaking:
            return peaking(ampl: ampl, cosine: cosine, alpha: alpha)
        case .lowShelf:
            return lowShelf(ampl: ampl, cosine: cosine, alpha: alpha)
        case .highShelf:
            return highShelf(ampl: ampl, cosine: cosine, alpha: alpha)
        }
    }

    private static func peaking(ampl: Double, cosine: Double, alpha: Double) -> RBJBiquad {
        let scale = 1 + alpha / ampl
        return RBJBiquad(
            numer0: (1 + alpha * ampl) / scale,
            numer1: -2 * cosine / scale,
            numer2: (1 - alpha * ampl) / scale,
            denom1: -2 * cosine / scale,
            denom2: (1 - alpha / ampl) / scale
        )
    }

    private static func lowShelf(ampl: Double, cosine: Double, alpha: Double) -> RBJBiquad {
        let sum = ampl + 1
        let diff = ampl - 1
        let slope = 2 * sqrt(ampl) * alpha
        let scale = sum + diff * cosine + slope
        return RBJBiquad(
            numer0: ampl * (sum - diff * cosine + slope) / scale,
            numer1: 2 * ampl * (diff - sum * cosine) / scale,
            numer2: ampl * (sum - diff * cosine - slope) / scale,
            denom1: -2 * (diff + sum * cosine) / scale,
            denom2: (sum + diff * cosine - slope) / scale
        )
    }

    private static func highShelf(ampl: Double, cosine: Double, alpha: Double) -> RBJBiquad {
        let sum = ampl + 1
        let diff = ampl - 1
        let slope = 2 * sqrt(ampl) * alpha
        let scale = sum - diff * cosine + slope
        return RBJBiquad(
            numer0: ampl * (sum + diff * cosine + slope) / scale,
            numer1: -2 * ampl * (diff + sum * cosine) / scale,
            numer2: ampl * (sum + diff * cosine - slope) / scale,
            denom1: 2 * (diff - sum * cosine) / scale,
            denom2: (sum - diff * cosine - slope) / scale
        )
    }
}

// MARK: - Evaluation

public extension RBJBiquad {
    /// The linear magnitude `|H(e^{jω})|` at `frequency`.
    ///
    /// Evaluated directly from the transfer function with `z⁻¹ = e^{−jω}`,
    /// split into real and imaginary parts (Foundation has no complex type).
    func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega), sin1 = sin(-omega)
        let cos2 = cos(2 * omega), sin2 = sin(-2 * omega)

        let numeratorReal = numer0 + numer1 * cos1 + numer2 * cos2
        let numeratorImaginary = numer1 * sin1 + numer2 * sin2
        let denominatorReal = 1 + denom1 * cos1 + denom2 * cos2
        let denominatorImaginary = denom1 * sin1 + denom2 * sin2

        let numeratorMagnitude = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominatorMagnitude = (
            denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        ).squareRoot()
        guard denominatorMagnitude > 0 else { return .infinity }
        return numeratorMagnitude / denominatorMagnitude
    }

    /// The magnitude at `frequency` expressed in dB.
    func responseDB(atFrequency frequency: Double, sampleRate: Double) -> Double {
        20 * log10(magnitude(atFrequency: frequency, sampleRate: sampleRate))
    }
}

// MARK: - Whole-configuration response

public extension ParametricEQConfiguration {
    /// The modelled combined response of every filter at `frequency`, in dB,
    /// **excluding** ``preampDB``.
    ///
    /// The filters are in series, so their dB responses add.
    func filterResponseDB(atFrequency frequency: Double, sampleRate: Double) -> Double {
        filters.reduce(0) { total, filter in
            total + RBJBiquad
                .make(for: filter, sampleRate: sampleRate)
                .responseDB(atFrequency: frequency, sampleRate: sampleRate)
        }
    }

    /// The modelled combined response at `frequency` in dB **including**
    /// ``preampDB`` — what the listener actually hears relative to bypass.
    func responseDB(atFrequency frequency: Double, sampleRate: Double) -> Double {
        preampDB + filterResponseDB(atFrequency: frequency, sampleRate: sampleRate)
    }
}
