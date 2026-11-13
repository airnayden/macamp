// SeparationAvailability — whether on-device stem separation can run right now.
//
// Karaoke mode depends on a bundled Core ML model (Mel-Band Roformer). That model
// is present in direct/Sparkle builds but deliberately ABSENT from App Store builds
// (license clearance pending) and from CI / fresh clones / iOS. Rather than model
// this as a `Bool`, the availability is an enum whose `.unavailable` case carries a
// TYPED reason — so the UI can explain WHY the feature is off and tests can assert
// the exact cause. The user-facing text lives on the reason as a
// `LocalizedStringResource` (never a raw `String`), keeping this file localizable
// by construction and AppKit/UIKit-free (PlayerCore portability invariant).
import Foundation

/// Whether stem separation (karaoke mode) is usable in the current build/session.
///
/// A `StemSeparating` conformer reports this so callers gate the feature before
/// attempting a `separate(url:progress:)`. `.available` means a compatible model is
/// loaded and ready; `.unavailable` explains why it is not.
public enum SeparationAvailability: Sendable, Equatable {
    /// A compatible separation model is loaded and ready to run.
    case available
    /// Separation cannot run; `reason` explains why (for UI + diagnostics).
    case unavailable(reason: SeparationUnavailableReason)

    /// `true` only in the `.available` case — a convenience for gating UI/logic
    /// without pattern-matching.
    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

/// The typed reason stem separation is unavailable.
///
/// Kept as a plain (associated-value-free) enum so ``SeparationAvailability`` stays
/// trivially `Equatable`/`Hashable`; the localized, user-facing explanation is a
/// computed ``message``.
public enum SeparationUnavailableReason: Sendable, Equatable, Hashable, CaseIterable {
    /// No separation model ships in this build (App Store build, CI, fresh clone,
    /// or iOS) — the unified "feature simply isn't here" path.
    case modelNotBundled
    /// A model is present but could not be loaded (corrupt, unreadable, or the
    /// Core ML compile/load failed).
    case modelLoadFailed
    /// A model loaded but is incompatible with this build — its manifest version
    /// or STFT parameters do not match what the pipeline expects.
    case incompatibleModel
    /// The track is one segment of a `.cue` sheet, and separation is keyed by the
    /// AUDIO FILE. All N segments of a disc image therefore collide on a single
    /// cache entry — the whole file's — so a rendered instrumental could not be
    /// attributed to the segment that asked for it. Unlike the three above this is a
    /// property of the TRACK, not of the build: the separator is fine, this row just
    /// cannot be offered to it.
    case cueSegment

    /// The user-facing explanation, resolved through the String Catalog.
    public var message: LocalizedStringResource {
        switch self {
        case .modelNotBundled:
            SeparationStrings.unavailableModelNotBundled
        case .modelLoadFailed:
            SeparationStrings.unavailableModelLoadFailed
        case .incompatibleModel:
            SeparationStrings.unavailableIncompatibleModel
        case .cueSegment:
            SeparationStrings.unavailableCueSegment
        }
    }
}
