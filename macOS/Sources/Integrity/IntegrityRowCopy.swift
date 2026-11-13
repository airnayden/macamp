// IntegrityRowCopy — outcome → catalog copy, and outcome → emphasis.
//
// Pure, exhaustive, and separate from the views so a new row state fails THESE
// switches to compile rather than reaching a listener as a blank cell.
//
// The two severities that exist here are not symmetric with the two outcome
// enums, and that asymmetry is the point:
//
//   * a checksum MISMATCH is `.bad` — it is a definite finding;
//   * a band-limited SPECTRUM is only `.caution` — the heuristic cannot establish
//     that anything is wrong, so it may never be drawn in the same register as a
//     proven mismatch;
//   * "no checksum stored", "not a FLAC stream" and every indeterminate reading
//     are `.neutral` — they mean nothing was established, which is neither good
//     news nor bad news.
import DSP
import ViewModels

/// How much emphasis a reading has earned.
enum IntegritySeverity: Equatable {
    /// A definite clean result.
    case good
    /// Nothing was established. Never styled as either a pass or a problem.
    case neutral
    /// Evidence worth a human's attention, but not a conclusion.
    case caution
    /// A definite finding.
    case bad
}

enum IntegrityRowCopy {
    // MARK: Checksum

    static func text(for outcome: IntegrityChecksumOutcome) -> LocalizedStringResource {
        switch outcome {
        case .match: IntegrityStrings.checksumMatch
        case .mismatch: IntegrityStrings.checksumMismatch
        case .noStoredMD5: IntegrityStrings.checksumNone
        case .notApplicable: IntegrityStrings.checksumNotApplicable
        case .notAttempted: IntegrityStrings.checksumNotAttempted
        case let .failed(failure): text(for: failure)
        }
    }

    static func text(for failure: IntegrityChecksumFailure) -> LocalizedStringResource {
        switch failure {
        case .unsupportedLayout: IntegrityStrings.checksumUnsupportedLayout
        case .decodeFailed: IntegrityStrings.checksumDecodeFailed
        case .unreadable: IntegrityStrings.checksumUnreadable
        case .unexpected: IntegrityStrings.checksumUnexpected
        }
    }

    static func severity(for outcome: IntegrityChecksumOutcome) -> IntegritySeverity {
        switch outcome {
        case .match: .good
        case .mismatch: .bad
        case .failed: .caution
        case .noStoredMD5, .notApplicable, .notAttempted: .neutral
        }
    }

    // MARK: Spectrum

    static func text(for outcome: IntegritySpectralOutcome) -> LocalizedStringResource {
        switch outcome {
        case let .consistent(cutoffHz):
            IntegrityStrings.spectrumConsistent(kilohertz: kilohertz(cutoffHz))
        case let .suspectTranscode(cutoffHz):
            IntegrityStrings.spectrumSuspect(kilohertz: kilohertz(cutoffHz))
        case let .indeterminate(reason):
            text(for: reason)
        case .failed:
            IntegrityStrings.spectrumFailed
        case .notAttempted:
            IntegrityStrings.spectrumNotAttempted
        }
    }

    static func text(for reason: SpectralIndeterminateReason) -> LocalizedStringResource {
        switch reason {
        case .insufficientAudio: IntegrityStrings.spectrumTooShort
        case .silentOrTooQuiet: IntegrityStrings.spectrumTooQuiet
        case .unusableSampleRate: IntegrityStrings.spectrumUnusableRate
        }
    }

    /// `.consistent` is `.neutral`, NOT `.good`: a full-band spectrum is not
    /// evidence of anything, and styling it as a pass would be the overclaim the
    /// heuristic's own contract forbids.
    static func severity(for outcome: IntegritySpectralOutcome) -> IntegritySeverity {
        switch outcome {
        case .suspectTranscode, .failed: .caution
        case .consistent, .indeterminate, .notAttempted: .neutral
        }
    }

    private static func kilohertz(_ hertz: Double) -> Double {
        hertz / 1000
    }
}
