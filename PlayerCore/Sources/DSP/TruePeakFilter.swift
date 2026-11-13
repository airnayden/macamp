/// TruePeakFilter — the ITU-R BS.1770-4 Annex 2 true-peak oversampling filter.
///
/// Annex 2 specifies a 48-tap linear-phase FIR that interpolates 4x, published
/// as four 12-tap polyphase branches. Branch `p` produces the output sample
/// sitting `p/4` of an input sample after the branch-0 one:
///
///     y[4n + p] = Σ(k = 0 ..< 12) phases[p][k] · x[n - k]
///
/// so index 0 of every branch multiplies the NEWEST input sample and index 11
/// the oldest. That convention is what makes the table below self-consistent:
/// reassembling the prototype as `h[4k + p] = phases[p][k]` yields a filter that
/// is symmetric about its centre (`h[m] == h[47 - m]`), with the two largest
/// taps 0.97216796875 landing on `h[23]`/`h[24]` exactly as a linear-phase
/// interpolator requires. `TruePeakMeterTests` asserts that symmetry so a
/// future edit cannot silently break the ordering.
///
/// The published table lists only phases 0 and 1 because that symmetry implies
/// the other two: `phases[2] == phases[1].reversed()` and
/// `phases[3] == phases[0].reversed()`.
///
/// The four branches are NOT equally flat — measured DC gains are 1.001587,
/// 0.973022, 0.973022, 1.001587. That is the published table, not a
/// transcription slip, and it is why a full-scale 997 Hz sine measures
/// +0.008 dBTP rather than exactly 0: the max lands on a branch-0/3 output,
/// which carries the +0.0138 dB DC gain. Do not "correct" the coefficients to
/// normalise it — the reading has to match every other BS.1770-4 meter.
enum TruePeakFilter {
    /// Interpolation factor — every input sample yields four filtered outputs.
    static let oversamplingFactor = 4

    /// Taps in each polyphase branch.
    static let tapsPerPhase = 12

    /// Past input samples one branch reaches back over, so the number of
    /// samples a block-at-a-time meter must carry across calls.
    static let historyLength = tapsPerPhase - 1

    /// The four polyphase branches, newest-sample-first (see the file comment).
    static let phases: [[Float]] = {
        // BS.1770-4 Annex 2, Table 3 — phase 0.
        let phase0: [Float] = [
            0.0017089843750,
            0.0109863281250,
            -0.0196533203125,
            0.0332031250000,
            -0.0594482421875,
            0.1373291015625,
            0.9721679687500,
            -0.1022949218750,
            0.0476074218750,
            -0.0266113281250,
            0.0148925781250,
            -0.0083007812500,
        ]
        // BS.1770-4 Annex 2, Table 3 — phase 1.
        let phase1: [Float] = [
            -0.0291748046875,
            0.0292968750000,
            -0.0517578125000,
            0.0891113281250,
            -0.1665039062500,
            0.4650878906250,
            0.7797851562500,
            -0.2003173828125,
            0.1015625000000,
            -0.0582275390625,
            0.0330810546875,
            -0.0189208984375,
        ]
        return [phase0, phase1, phase1.reversed(), phase0.reversed()]
    }()

    /// The 48-tap prototype the four branches decompose, `h[4k + p]` ordered.
    ///
    /// Nothing on the metering path reads this — it exists so the symmetry that
    /// justifies the two reversed branches can be asserted directly.
    static var prototype: [Float] {
        var taps = [Float](repeating: 0, count: oversamplingFactor * tapsPerPhase)
        for (phaseIndex, phase) in phases.enumerated() {
            for (tapIndex, tap) in phase.enumerated() {
                taps[tapIndex * oversamplingFactor + phaseIndex] = tap
            }
        }
        return taps
    }
}
