// DownloadError — the typed failure ladder for the YouTube audio downloader.
//
// Every stage of a download (tool resolution → metadata prefetch → transfer →
// post-processing → move into the destination) maps its failure onto one of these
// cases, so callers pattern-match a small, stable set instead of inspecting an
// engine exit code or an opaque `NSError`. The value-carrying cases exist because
// the engine hands back diagnostic text (`detail`) or an exit code the app does not
// recognize (`unknown`); the user-facing text is always a `LocalizedStringResource`,
// never a raw `String` (PlayerCore localization rule), and `detail` is a DIAGNOSTIC
// — it is never presented as the primary message.
//
// Mirrors `SeparationError`'s shape (typed, `Sendable`, `Equatable`, `message` +
// `LocalizedError` bridge). Unlike that enum it is NOT `CaseIterable`: the associated
// values make an exhaustive value list meaningless.
import Foundation

/// A typed error surfaced by the download queue and the download tool manager.
public enum DownloadError: Error, Sendable, Equatable, Hashable {
    /// The transfer itself failed. `detail` carries engine diagnostics for logging.
    case downloadFailed(detail: String?)
    /// The engine rejected the arguments it was given (a programming error).
    case invalidArguments
    /// The engine reported that it must be relaunched before it can continue.
    case engineRestartRequired
    /// The person cancelled the download.
    case cancelled
    /// The engine stopped the download on its own (not a person-initiated cancel).
    case cancelledByEngine
    /// The destination already holds this video's audio file.
    case alreadyDownloaded
    /// The configured downloads folder is missing, unreadable, or not writable.
    case destinationUnavailable
    /// The bundled/updated download tools could not be located on disk.
    case toolMissing
    /// A manual engine self-update did not complete. `detail` carries diagnostics.
    case updateFailed(detail: String?)
    /// The engine exited with a code the app does not map to any case above.
    case unknown(code: Int32)

    /// The user-facing explanation, resolved through the String Catalog.
    ///
    /// Deliberately independent of the associated values: `detail` is engine output
    /// (untranslatable, often English-only) and `code` is a number — neither belongs
    /// in the primary message. Surfaces that want diagnostics read ``detail`` directly.
    public var message: LocalizedStringResource {
        switch self {
        case .downloadFailed:
            DownloadsStrings.errorDownloadFailed
        case .invalidArguments:
            DownloadsStrings.errorInvalidArguments
        case .engineRestartRequired:
            DownloadsStrings.errorEngineRestartRequired
        case .cancelled:
            DownloadsStrings.errorCancelled
        case .cancelledByEngine:
            DownloadsStrings.errorCancelledByEngine
        case .alreadyDownloaded:
            DownloadsStrings.errorAlreadyDownloaded
        case .destinationUnavailable:
            DownloadsStrings.errorDestinationUnavailable
        case .toolMissing:
            DownloadsStrings.errorToolMissing
        case .updateFailed:
            DownloadsStrings.errorUpdateFailed
        case .unknown:
            DownloadsStrings.errorUnknown
        }
    }

    /// The untranslated engine diagnostics attached to this failure, when any.
    ///
    /// For logging and a disclosure row — never the primary user-facing message.
    public var detail: String? {
        switch self {
        case let .downloadFailed(detail), let .updateFailed(detail):
            detail
        default:
            nil
        }
    }

    /// Whether a user or the engine stopped the download before it finished.
    public var isCancellation: Bool {
        switch self {
        case .cancelled, .cancelledByEngine:
            true
        default:
            false
        }
    }
}

// MARK: - LocalizedError bridge

extension DownloadError: LocalizedError {
    /// Resolves ``message`` to a `String` at the `LocalizedError` boundary (the only
    /// place a `String` is required); the source of truth stays a
    /// `LocalizedStringResource`.
    public var errorDescription: String? {
        String(localized: message)
    }

    /// Surfaces engine diagnostics through the standard `NSError` userInfo channel
    /// so logs keep the detail the localized message deliberately omits.
    public var failureReason: String? {
        detail
    }
}
