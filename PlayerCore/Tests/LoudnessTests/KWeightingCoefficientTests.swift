// KWeightingCoefficientTests — the regression anchor for the BS.1770-4
// K-weighting filter: the bilinear re-derivation used at every sample rate
// must reduce EXACTLY to the recommendation's published 48 kHz tables.
//
// Without this, a plausible-looking edit to either stage changes every
// loudness reading in the app by a fraction of a dB and nothing else notices.
import Foundation
import Services
import Testing

struct KWeightingCoefficientTests {
    /// Tight enough that only floating-point rounding can pass — a real
    /// algebraic difference is orders of magnitude larger.
    private let tolerance = 1e-10

    // MARK: Table regression

    @Test("stage 1 re-derived at 48 kHz matches BS.1770-4 Table 1")
    func stage1MatchesPublishedTable() {
        expectCoefficients(
            KWeightingCoefficients.stage1(sampleRate: 48000),
            match: KWeightingCoefficients.publishedStage1At48kHz
        )
    }

    @Test("stage 2 re-derived at 48 kHz matches BS.1770-4 Table 2")
    func stage2MatchesPublishedTable() {
        expectCoefficients(
            KWeightingCoefficients.stage2(sampleRate: 48000),
            match: KWeightingCoefficients.publishedStage2At48kHz
        )
    }

    // MARK: The un-normalised stage-2 numerator

    @Test("stage 2's numerator stays {1, −2, 1} at every sample rate")
    func stage2NumeratorIsNeverNormalised() {
        for sampleRate in [44100.0, 48000.0, 88200.0, 96000.0, 192_000.0] {
            let stage = KWeightingCoefficients.stage2(sampleRate: sampleRate)
            #expect(stage.forward0 == 1.0)
            #expect(stage.forward1 == -2.0)
            #expect(stage.forward2 == 1.0)
        }
    }

    /// Dividing stage 2's numerator by its own `a0Den` is the tempting
    /// "symmetry fix" with stage 1, and it costs a flat −0.0433 dB at every
    /// frequency. This pins the size of that error so the previous test's
    /// intent survives a rewrite that no longer states it.
    @Test("normalising stage 2's numerator would bias the response by −0.0433 dB")
    func normalisingStage2NumeratorWouldBias() {
        let stage = KWeightingCoefficients.stage2(sampleRate: 48000)
        // Recovered from the published feedback pair: eliminating K/Q and K²
        // from a1 = 2(K²−1)/a0Den and a2 = (1−K/Q+K²)/a0Den leaves this.
        let a0Den = 4.0 / (1.0 + stage.feedback2 - stage.feedback1)
        #expect(abs(20.0 * log10(1.0 / a0Den) + 0.0433) < 0.0005)
    }

    // MARK: Filter shape

    @Test("the cascade adds +0.691 dB at 997 Hz, cancelling the −0.691 calibration")
    func cascadeGainAt997HzCancelsCalibration() {
        for sampleRate in [44100.0, 48000.0] {
            let gainDB = 20.0 * log10(cascadeMagnitude(at: 997, sampleRate: sampleRate))
            #expect(abs(gainDB + LoudnessGating.calibrationOffsetDB) < 0.005)
        }
    }

    @Test("the RLB stage rejects sub-audio rumble and passes the midband")
    func highPassRejectsRumble() {
        let rumble = 20.0 * log10(cascadeMagnitude(at: 10, sampleRate: 48000))
        let midband = 20.0 * log10(cascadeMagnitude(at: 1000, sampleRate: 48000))
        #expect(rumble < -20)
        #expect(abs(midband) < 1)
    }

    // MARK: Helpers

    private func expectCoefficients(_ derived: LoudnessBiquad, match published: LoudnessBiquad) {
        let names = ["b0", "b1", "b2", "a1", "a2"]
        for (index, pair) in zip(derived.deq22Coefficients, published.deq22Coefficients).enumerated() {
            #expect(abs(pair.0 - pair.1) < tolerance, "\(names[index]): \(pair.0) vs \(pair.1)")
        }
    }

    /// `|H(e^{jω})|` of the two cascaded sections, evaluated directly from the
    /// coefficients rather than by filtering — an independent check of the
    /// numbers the filter will actually use.
    private func cascadeMagnitude(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let stages = [
            KWeightingCoefficients.stage1(sampleRate: sampleRate),
            KWeightingCoefficients.stage2(sampleRate: sampleRate),
        ]
        return stages.reduce(1.0) { total, stage in
            let (cos1, sin1) = (cos(omega), sin(omega))
            let (cos2, sin2) = (cos(2 * omega), sin(2 * omega))
            let numeratorReal = stage.forward0 + stage.forward1 * cos1 + stage.forward2 * cos2
            let numeratorImaginary = -(stage.forward1 * sin1 + stage.forward2 * sin2)
            let denominatorReal = 1.0 + stage.feedback1 * cos1 + stage.feedback2 * cos2
            let denominatorImaginary = -(stage.feedback1 * sin1 + stage.feedback2 * sin2)
            let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
            let denominator = (denominatorReal * denominatorReal
                + denominatorImaginary * denominatorImaginary).squareRoot()
            return total * (numerator / denominator)
        }
    }
}
