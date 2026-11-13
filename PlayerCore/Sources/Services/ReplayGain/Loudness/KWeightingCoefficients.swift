//
//  KWeightingCoefficients.swift
//  MacAMP PlayerCore — Services
//
//  ITU-R BS.1770-4 K-weighting: the two cascaded biquads every loudness
//  measurement runs its input through before a single sample of energy is
//  summed. Stage 1 is the +4 dB "head effect" high shelf; stage 2 is the RLB
//  high-pass that discards sub-audio rumble.
//
//  The published Tables 1-2 give the coefficients at 48 kHz ONLY. Every other
//  sample rate is re-derived here from the analog prototypes by the bilinear
//  transform — and that derivation reduces EXACTLY to the published tables at
//  48 kHz, which ``KWeightingCoefficientTests`` asserts to 1e-10 so a future
//  edit cannot drift the two apart.
//
//  This file imports only Foundation; it MUST NOT import AppKit or UIKit
//  (PlayerCore portability invariant).
//

import Foundation

// MARK: - LoudnessBiquad

/// One Direct-Form-I biquad section with an **implicit `a0 == 1`**.
///
/// The five stored coefficients are the BS.1770-4 table columns; each property
/// documents the symbol it carries. The difference equation is
/// `y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]`, which is
/// exactly what `vDSP_deq22D` evaluates.
public struct LoudnessBiquad: Sendable, Equatable {
    /// `b0` — feed-forward gain on the current input sample.
    public let forward0: Double
    /// `b1` — feed-forward gain on the previous input sample.
    public let forward1: Double
    /// `b2` — feed-forward gain on the input sample before that.
    public let forward2: Double
    /// `a1` — feed-back gain on the previous output sample.
    public let feedback1: Double
    /// `a2` — feed-back gain on the output sample before that.
    public let feedback2: Double

    public init(
        forward0: Double,
        forward1: Double,
        forward2: Double,
        feedback1: Double,
        feedback2: Double
    ) {
        self.forward0 = forward0
        self.forward1 = forward1
        self.forward2 = forward2
        self.feedback1 = feedback1
        self.feedback2 = feedback2
    }

    /// The five coefficients in `vDSP_deq22D`'s expected order:
    /// `[b0, b1, b2, a1, a2]`.
    public var deq22Coefficients: [Double] {
        [forward0, forward1, forward2, feedback1, feedback2]
    }
}

// MARK: - KWeightingCoefficients

/// Derives both K-weighting stages for any sample rate.
///
/// Pure value math — no state, no allocation beyond the returned structs.
public enum KWeightingCoefficients {
    // MARK: Analog prototypes (BS.1770-4)

    /// Stage 1 shelf corner frequency (Hz).
    private static let shelfCornerHz = 1681.974450955533
    /// Stage 1 shelf gain (dB) — the "+4 dB" head effect, to full precision.
    private static let shelfGainDB = 3.999843853973347
    /// Stage 1 shelf Q.
    private static let shelfQuality = 0.7071752369554196
    /// Exponent relating the shelf's mid-band gain `Vb` to its high-band gain
    /// `Vh` (`Vb = Vh^this`). Not `0.5` — the published value is what makes the
    /// derivation land on Table 1 exactly.
    private static let shelfMidGainExponent = 0.4996667741545416

    /// Stage 2 RLB high-pass corner frequency (Hz).
    private static let highPassCornerHz = 38.13547087602444
    /// Stage 2 RLB high-pass Q.
    private static let highPassQuality = 0.5003270373238773

    // MARK: Derivation

    /// Stage 1 — the high shelf that models the acoustic effect of the head.
    ///
    /// The whole section (numerator **and** denominator) is normalised by
    /// `a0Den`, so the returned `a0` is 1 by construction.
    ///
    /// - Note: `a0Den` is deliberately NOT called `a0`. The biquad's own `a0`
    ///   is 1 and implicit; `a0Den` is only the bilinear-transform divisor.
    ///   Confusing the two is precisely the mistake stage 2 guards against.
    public static func stage1(sampleRate: Double) -> LoudnessBiquad {
        let warp = tan(.pi * shelfCornerHz / sampleRate) // K
        let warpSquared = warp * warp // K²
        let highGain = pow(10.0, shelfGainDB / 20.0) // Vh
        let midGain = pow(highGain, shelfMidGainExponent) // Vb
        let damping = warp / shelfQuality // K/Q
        let a0Den = 1.0 + damping + warpSquared

        return LoudnessBiquad(
            forward0: (highGain + midGain * damping + warpSquared) / a0Den,
            forward1: 2.0 * (warpSquared - highGain) / a0Den,
            forward2: (highGain - midGain * damping + warpSquared) / a0Den,
            feedback1: 2.0 * (warpSquared - 1.0) / a0Den,
            feedback2: (1.0 - damping + warpSquared) / a0Den
        )
    }

    /// Stage 2 — the RLB high-pass.
    ///
    /// The numerator is **UN-NORMALISED**: `b = {1, −2, 1}` exactly, never
    /// divided by `a0Den`. Dividing it looks symmetric with stage 1 and is
    /// wrong — it introduces a −0.0433 dB broadband bias and fails the Table 2
    /// regression check. Only `a1` and `a2` are divided, by an `a0Den`
    /// recomputed from *this* stage's corner and Q.
    public static func stage2(sampleRate: Double) -> LoudnessBiquad {
        let warp = tan(.pi * highPassCornerHz / sampleRate) // K
        let warpSquared = warp * warp // K²
        let damping = warp / highPassQuality // K/Q
        let a0Den = 1.0 + damping + warpSquared

        return LoudnessBiquad(
            forward0: 1.0,
            forward1: -2.0,
            forward2: 1.0,
            feedback1: 2.0 * (warpSquared - 1.0) / a0Den,
            feedback2: (1.0 - damping + warpSquared) / a0Den
        )
    }

    // MARK: Published tables (regression anchors)

    /// BS.1770-4 Table 1 — stage 1 at 48 kHz, as printed in the recommendation.
    ///
    /// Only ``KWeightingCoefficientTests`` reads this: production always goes
    /// through ``stage1(sampleRate:)``, and the test proves the two agree.
    public static let publishedStage1At48kHz = LoudnessBiquad(
        forward0: 1.53512485958697,
        forward1: -2.69169618940638,
        forward2: 1.19839281085285,
        feedback1: -1.69065929318241,
        feedback2: 0.73248077421585
    )

    /// BS.1770-4 Table 2 — stage 2 at 48 kHz, as printed in the recommendation.
    public static let publishedStage2At48kHz = LoudnessBiquad(
        forward0: 1.0,
        forward1: -2.0,
        forward2: 1.0,
        feedback1: -1.99004745483398,
        feedback2: 0.99007225036621
    )
}
