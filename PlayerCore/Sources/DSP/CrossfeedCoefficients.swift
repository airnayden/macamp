import Foundation

/// A crossfeed strength setting: the lowpass cut frequency and the feeding level.
///
/// Both components are clamped into the legal bs2b range on construction, so an
/// out-of-range value from a settings file or a stale preference can never reach
/// the coefficient derivation.
public struct CrossfeedLevel: Sendable, Equatable, Hashable {
    /// Legal lowpass cut frequency in Hz (`BS2B_MINFCUT` … `BS2B_MAXFCUT`).
    public static let cutFrequencyRange: ClosedRange<Double> = 300 ... 2000
    /// Legal feeding level in dB (`BS2B_MINFEED` … `BS2B_MAXFEED`).
    public static let feedRange: ClosedRange<Double> = 1 ... 15

    /// Lowpass cut frequency in Hz, clamped to ``cutFrequencyRange``.
    public let cutFrequency: Double
    /// Feeding level in dB, clamped to ``feedRange``.
    public let feedDB: Double

    /// Clamps both components into their legal range.
    ///
    /// Out-of-range input is clamped per component. libbs2b itself discards the
    /// whole level and reverts to its default when either component is illegal;
    /// clamping preserves the user's intent on the component that *was* legal,
    /// which matters when only one of the two sliders is stale.
    public init(cutFrequency: Double, feedDB: Double) {
        self.cutFrequency = cutFrequency.clamped(to: Self.cutFrequencyRange)
        self.feedDB = feedDB.clamped(to: Self.feedRange)
    }
}

public extension CrossfeedLevel {
    /// The bs2b default — a neutral, mild crossfeed.
    static let `default` = CrossfeedLevel(cutFrequency: 700, feedDB: 4.5)
    /// Chu Moy's headphone amplifier crossfeed.
    static let cmoy = CrossfeedLevel(cutFrequency: 700, feedDB: 6.0)
    /// Jan Meier's headphone amplifier crossfeed.
    static let jmeier = CrossfeedLevel(cutFrequency: 650, feedDB: 9.5)
}

/// The derived one-pole filter coefficients for a single crossfeed setting.
///
/// Derivation follows libbs2b 3.1.0 (`bs2b.c`, `init()`) exactly — that C code is
/// the oracle the kernel is tested against (`tools/fixtures/bs2b/`). Symbol names
/// follow the work plan:
///
/// - `Gd`   — lowpass-path gain in dB: `−(5/6)·feed − 3`
/// - `Gd_h` — highboost attenuation in dB: `feed/6 − 3`
/// - `G`    — linear lowpass gain: `10^(Gd/20)`
/// - `G_h`  — linear highboost gain: `1 − 10^(Gd_h/20)`
/// - `Fc_h` — highboost cut frequency: `fcut · 2^((Gd − 20·log₁₀(G_h))/12)`
/// - `x`    — lowpass pole: `exp(−2π·fcut/fs)`
/// - `x_h`  — highboost pole: `exp(−2π·Fc_h/fs)`
///
/// > Deviation from the work plan: the plan wrote `Fc_h = fcut·2^((Gd − Gd_h)/12)`,
/// > using the attenuation dB where libbs2b uses `20·log₁₀(G_h)` — the dB value of
/// > the *linear* gain `G_h`. They differ substantially (≈540 Hz vs ≈994 Hz on the
/// > default preset), and only libbs2b's expression reproduces the committed
/// > reference vectors. See `tools/fixtures/bs2b/README.md`.
public struct CrossfeedCoefficients: Sendable, Equatable {
    /// Lowpass feedback coefficient (`b1 = x`).
    public let lowpassB1: Double
    /// Lowpass input coefficient (`a0 = G·(1 − x)`).
    public let lowpassA0: Double
    /// Highboost feedback coefficient (`b1 = x_h`).
    public let highboostB1: Double
    /// Highboost input coefficient (`a0 = 1 − G_h·(1 − x_h)`).
    public let highboostA0: Double
    /// Highboost one-sample-delayed input coefficient (`a1 = −x_h`).
    public let highboostA1: Double
    /// Output compensation gain, `1/(1 − G_h + G)`, applied inside the kernel's
    /// output stage so the DC response stays unity.
    public let outputGain: Double

    /// Linear lowpass gain `G`. Retained so tests can assert the DC identity
    /// `(1 − G_h + G)·outputGain == 1` without re-deriving it.
    public let linearLowpassGain: Double
    /// Linear highboost gain `G_h`. Retained for the same reason as
    /// ``linearLowpassGain``.
    public let linearHighboostGain: Double

    /// Derives the coefficients for `level` at `sampleRate`.
    ///
    /// - Parameters:
    ///   - level: the (already clamped) crossfeed strength.
    ///   - sampleRate: the render sample rate in Hz. Must be positive.
    public init(level: CrossfeedLevel, sampleRate: Double) {
        precondition(sampleRate > 0, "sampleRate must be positive")

        let feed = level.feedDB
        let cutFrequency = level.cutFrequency

        // Path gains in dB: Gd and Gd_h.
        let gainDB = feed * -5.0 / 6.0 - 3.0
        let gainHighDB = feed / 6.0 - 3.0

        // Linear path gains: G and G_h.
        let lowGain = pow(10.0, gainDB / 20.0)
        let highGain = 1.0 - pow(10.0, gainHighDB / 20.0)

        // Fc_h. Uses `20·log₁₀(G_h)`, NOT `Gd_h` — see the type doc.
        let cutFrequencyHigh = cutFrequency * pow(2.0, (gainDB - 20.0 * log10(highGain)) / 12.0)

        // One-pole poles: x = exp(−1/d) with d = 1/(2π·(Fc/fs)).
        let pole = exp(-2.0 * .pi * cutFrequency / sampleRate)
        let poleHigh = exp(-2.0 * .pi * cutFrequencyHigh / sampleRate)

        lowpassB1 = pole
        lowpassA0 = lowGain * (1.0 - pole)
        highboostB1 = poleHigh
        highboostA0 = 1.0 - highGain * (1.0 - poleHigh)
        highboostA1 = -poleHigh
        outputGain = 1.0 / (1.0 - highGain + lowGain)

        linearLowpassGain = lowGain
        linearHighboostGain = highGain
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
