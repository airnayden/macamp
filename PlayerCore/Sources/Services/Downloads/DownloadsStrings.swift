// DownloadsStrings — every user-facing string in the Downloads surface of Services.
//
// Centralized as `LocalizedStringResource` keys with an English `defaultValue`,
// exactly like `SeparationStrings`. The Downloads code never emits a bare literal —
// error copy references these constants — so it is localization-clean by
// construction. Until the app String Catalogs sync the keys, the `defaultValue`
// renders. Dotted keys follow the project convention (`downloads.<area>.<case>`).
//
// NOTE: `scripts/check-hardcoded-strings.sh` does NOT scan PlayerCore, so this file's
// discipline is a hand-verified code-review invariant, not a CI gate.
import Foundation

/// Localized copy for ``DownloadError`` and the download queue's user-facing states.
public enum DownloadsStrings {
    // MARK: Errors

    public static let errorDownloadFailed = LocalizedStringResource(
        "downloads.error.downloadFailed",
        defaultValue: "The download failed.",
        comment: "Shown when the download engine reported a generic download failure"
    )
    public static let errorInvalidArguments = LocalizedStringResource(
        "downloads.error.invalidArguments",
        defaultValue: "This download couldn't be started because the request was invalid.",
        comment: "Shown when the download engine rejected the request it was given"
    )
    public static let errorEngineRestartRequired = LocalizedStringResource(
        "downloads.error.engineRestartRequired",
        defaultValue: "The download engine needs to restart. Try this download again.",
        comment: "Shown when the download engine asked to be relaunched before continuing"
    )
    public static let errorCancelled = LocalizedStringResource(
        "downloads.error.cancelled",
        defaultValue: "The download was cancelled.",
        comment: "Shown when the person cancelled the download"
    )
    public static let errorCancelledByEngine = LocalizedStringResource(
        "downloads.error.cancelledByEngine",
        defaultValue: "The download engine stopped this download.",
        comment: "Shown when the engine itself stopped the download, not the person"
    )
    public static let errorAlreadyDownloaded = LocalizedStringResource(
        "downloads.error.alreadyDownloaded",
        defaultValue: "This video has already been downloaded.",
        comment: "Shown when the destination already holds this video's audio file"
    )
    public static let errorDestinationUnavailable = LocalizedStringResource(
        "downloads.error.destinationUnavailable",
        defaultValue: "The downloads folder isn't available.",
        comment: "Shown when the configured downloads folder is missing or not writable"
    )
    public static let errorToolMissing = LocalizedStringResource(
        "downloads.error.toolMissing",
        defaultValue: "The download engine isn't installed.",
        comment: "Shown when the bundled yt-dlp / ffmpeg tools could not be located"
    )
    public static let errorUpdateFailed = LocalizedStringResource(
        "downloads.error.updateFailed",
        defaultValue: "The download engine couldn't be updated.",
        comment: "Shown when a manual engine self-update did not complete"
    )
    public static let errorUnknown = LocalizedStringResource(
        "downloads.error.unknown",
        defaultValue: "The download stopped for an unknown reason.",
        comment: "Shown when the engine exited with a code the app does not recognize"
    )
}
