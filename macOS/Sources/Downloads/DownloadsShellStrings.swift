// Download copy owned by the macOS shell, kept out of `MacAMPStrings.swift` so that
// file stays within the SwiftLint type-body-length / file-length budgets. These remain
// `MacAMPStrings` members (referenced as `MacAMPStrings.downloadImportedToast` etc.)
// via this extension — the same shape `KaraokeQueueStrings.swift` uses.
//
// The engine-facing failure sentences live in `DownloadsStrings` (PlayerCore
// `Services`, reached through `DownloadError.message`); everything here is copy only
// the shell can write, because only the shell knows about System Settings and toasts.
import Foundation

extension MacAMPStrings {
    static let downloadImportedToast = LocalizedStringResource(
        "app.downloads.toast.imported",
        defaultValue: "Added to your library",
        comment: "Toast shown when a finished download has been imported into the library"
    )
    /// The recovery sentence for ``DownloadError/destinationUnavailable``.
    ///
    /// Names the exact System Settings location as well as opening it, because the
    /// toast that carries this text is non-interactive: a listener who misses the
    /// window that opened still knows where to go.
    static let downloadDestinationGrantAccessToast = LocalizedStringResource(
        "app.downloads.toast.grantAccess",
        defaultValue: "MacAMP can’t write to your downloads folder. Grant access in Privacy & Security ▸ Files and Folders, or choose another folder in Settings ▸ Downloads.",
        comment: "Toast shown when the downloads destination folder cannot be written to, pointing at the macOS privacy setting that grants access"
    )
}
