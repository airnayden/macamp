// FakeLosslessVerdict — the heuristic reading of a spectral cutoff.
//
// ⚠️ THIS IS A HEURISTIC AND NOTHING IT PRODUCES IS PROOF. A band-limited
// spectrum is evidence that a stream PASSED THROUGH a lossy stage at some point;
// it can never establish that it did, and it can never establish that it did not.
// Legitimate lossless material is band-limited all the time — an analogue master,
// a deliberately filtered mix, an instrument that simply has no content up there.
//
// The vocabulary is chosen so a caller cannot accidentally overclaim: the only
// negative case is `suspectTranscode`, and there is no case named `fake`,
// `confirmed` or `proven`. Every user-facing surface must keep that register.
import Foundation

/// What a measured spectral cutoff suggests about a file's lossless claim.
public enum FakeLosslessVerdict: Sendable, Equatable {
    /// The spectrum runs as high as the sample rate allows. Nothing to report —
    /// which is NOT the same as "verified lossless"; this heuristic cannot
    /// establish that.
    case consistent(cutoffHz: Double)

    /// The spectrum stops early enough to look like the lowpass a lossy encoder
    /// leaves behind. Grounds for a closer look by a human, never a conclusion.
    case suspectTranscode(cutoffHz: Double)

    /// No estimate could be made. NOT a clean result — nothing was measured.
    case indeterminate(SpectralIndeterminateReason)

    public var cutoffHz: Double? {
        switch self {
        case let .consistent(cutoffHz), let .suspectTranscode(cutoffHz):
            cutoffHz
        case .indeterminate:
            nil
        }
    }

    public var isSuspect: Bool {
        if case .suspectTranscode = self { return true }
        return false
    }
}

/// Turns a measured ``SpectralCutoffOutcome`` into a ``FakeLosslessVerdict``.
public enum FakeLosslessRule {
    /// A cutoff must fall below this fraction of Nyquist to be suspicious.
    ///
    /// Real lossless content routinely stops a little short of Nyquist — the
    /// anti-alias filter of whatever produced it, or simply no energy up there —
    /// so the band immediately under Nyquist has to be treated as normal.
    public static let suspectCutoffRatio = 0.86

    /// …and it must also fall below the top of human hearing. A 96 kHz file
    /// stopping at 21 kHz is 0.44 of Nyquist and completely unremarkable; without
    /// this second condition every hi-res file would be reported.
    public static let suspectCutoffCeilingHz = 20000.0

    public static func verdict(for outcome: SpectralCutoffOutcome) -> FakeLosslessVerdict {
        switch outcome {
        case let .indeterminate(reason):
            .indeterminate(reason)
        case let .estimated(estimate):
            if isSuspect(estimate) {
                .suspectTranscode(cutoffHz: estimate.cutoffHz)
            } else {
                .consistent(cutoffHz: estimate.cutoffHz)
            }
        }
    }

    private static func isSuspect(_ estimate: SpectralCutoffEstimate) -> Bool {
        estimate.cutoffRatio < suspectCutoffRatio && estimate.cutoffHz < suspectCutoffCeilingHz
    }
}
