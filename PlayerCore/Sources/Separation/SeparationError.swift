// SeparationError — the typed failure ladder for the stem-separation pipeline.
//
// Every stage of the offline pipeline (decode → resample → STFT → Core ML → iSTFT →
// ALAC encode → cache) maps its failure onto one of these cases, so callers pattern-
// match a small, stable set instead of inspecting opaque `NSError`s. The cases are
// value-free so the enum is trivially `Equatable` (tests do `#expect(throws:
// SeparationError.modelUnavailable)`); the user-facing text is a
// `LocalizedStringResource`, never a raw `String` (PlayerCore localization rule).
import Foundation

/// A typed error thrown by the stem-separation pipeline and its stages.
public enum SeparationError: Error, Sendable, Equatable, Hashable, CaseIterable {
    /// No compatible separation model is available (not bundled, or failed to load).
    case modelUnavailable
    /// The source has a channel layout the pipeline cannot handle (> 2 channels).
    case unsupportedChannelLayout
    /// The source audio could not be decoded.
    case decodeFailed
    /// Core ML inference failed while separating a segment.
    case inferenceFailed
    /// Encoding the separated instrumental (ALAC) failed.
    case encodeFailed
    /// The device ran out of disk space while writing the instrumental/cache.
    case diskFull
    /// The result cannot fit the cache limit while preserving pinned audio.
    case cacheCapacityExceeded

    /// The user-facing explanation, resolved through the String Catalog.
    public var message: LocalizedStringResource {
        switch self {
        case .modelUnavailable:
            SeparationStrings.errorModelUnavailable
        case .unsupportedChannelLayout:
            SeparationStrings.errorUnsupportedChannelLayout
        case .decodeFailed:
            SeparationStrings.errorDecodeFailed
        case .inferenceFailed:
            SeparationStrings.errorInferenceFailed
        case .encodeFailed:
            SeparationStrings.errorEncodeFailed
        case .diskFull:
            SeparationStrings.errorDiskFull
        case .cacheCapacityExceeded:
            SeparationStrings.errorCacheCapacityExceeded
        }
    }
}

// MARK: - LocalizedError bridge

extension SeparationError: LocalizedError {
    /// Resolves ``message`` to a `String` at the `LocalizedError` boundary (the only
    /// place a `String` is required); the source of truth stays a
    /// `LocalizedStringResource`.
    public var errorDescription: String? {
        String(localized: message)
    }
}
