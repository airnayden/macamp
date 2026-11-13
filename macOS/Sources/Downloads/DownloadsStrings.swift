// Downloads copy, kept out of `MacAMPStrings.swift` so that file stays within the
// SwiftLint type-body-length / file-length budgets. These remain `MacAMPStrings`
// members (referenced as `MacAMPStrings.sidebarDownloads`) via this extension.
//
// This file carries the SIDEBAR and TOAST copy; the paste sheet's lives in
// `DownloadsPasteStrings.swift` and the queue pane's in `DownloadsQueueStrings.swift`,
// each split for the same 400-line budget.
//
// NOTE ON THE NAMESPACE: the engine-facing failure sentences live in
// `Services.DownloadsStrings` (reached through `DownloadError.message`). The shell's
// own copy deliberately does NOT extend that enum — its header claims to be "every
// user-facing string in the Downloads surface of Services", and shell copy about
// sheets, toasts and System Settings is not that. `MacAMPStrings` is the shell's
// namespace and stays the shell's namespace.
import Foundation

extension MacAMPStrings {
    static let sidebarDownloads = LocalizedStringResource(
        "app.sidebar.downloads",
        defaultValue: "Downloads",
        comment: "Sidebar item and pane title for the YouTube download queue"
    )

    // MARK: - Toasts

    /// The queue-complete toast: fired ONCE when a drain that actually produced files
    /// empties, never per item.
    static func downloadsFinishedToast(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.toast.finished",
            defaultValue: "^[\(count) download](inflect: true) finished",
            comment: "Toast shown once when the download queue empties after finishing work"
        ))
    }

    static func downloadsEngineUpdatedToast(_ version: String) -> String {
        String(localized: LocalizedStringResource(
            "app.downloads.toast.engineUpdated",
            defaultValue: "Download engine updated to \(version)",
            comment: "Toast shown after the download engine successfully self-updated"
        ))
    }

    static let downloadsEngineUpdateFailedToast = LocalizedStringResource(
        "app.downloads.toast.engineUpdateFailed",
        defaultValue: "The download engine couldn’t be updated.",
        comment: "Toast shown when a download-engine self-update did not complete"
    )

    // MARK: - Inflection

    /// `String(localized:)` does NOT run `^[…](inflect: true)` morphology on an inline
    /// `defaultValue` (it returns the raw markup); `AttributedString` does. Shared by
    /// every counted Downloads string across the three Downloads string files, which
    /// is why it is internal rather than `private`.
    static func downloadsInflected(_ resource: LocalizedStringResource) -> String {
        String(AttributedString(localized: resource).characters)
    }
}
