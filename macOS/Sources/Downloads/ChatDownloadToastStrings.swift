// Chat-download toast copy — what the listener is told about a download the assistant
// started on their behalf.
//
// A separate file from `DownloadsStrings.swift` for the same 400-line budget reason
// that file gives for existing, and these remain `MacAMPStrings` members through this
// extension.
//
// TWO RULES SHAPE EVERY SENTENCE HERE.
//
//   1. It says what happened to the PLAYLIST, not to the download. The queue row
//      already renders its own transfer error, and `DownloadToastPolicy` already
//      announces the drain. Repeating either would report one fault twice; what
//      neither of them can say is "…so it never reached the playlist you asked for".
//   2. A sentence that names a fix names BOTH exits, the way
//      ``downloadsAutoImportOffCaption`` does for the same gate — the listener can
//      turn on automatic import, or point a library root at the download folder, and
//      a notice that mentions only one of them reads as a dead end.
//
// The counted summary goes through ``MacAMPStrings/downloadsInflected(_:)``, because
// `String(localized:)` returns `^[…](inflect: true)` markup verbatim and only
// `AttributedString` runs the morphology.
import Foundation

extension MacAMPStrings {
    // MARK: - The summary

    /// The one toast a batch of successful appends produces, naming the playlist.
    static func chatDownloadAddedToast(_ count: Int, playlist: String) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.chat.toast.added",
            defaultValue: "Added ^[\(count) track](inflect: true) to “\(playlist)”",
            comment: "Toast summarising how many downloaded tracks were added to one named playlist"
        ))
    }

    /// The same summary for a playlist whose name could not be read.
    ///
    /// A separate sentence rather than an empty interpolation: a toast reading
    /// `Added 3 tracks to “”` is worse than one that simply does not name the playlist.
    static func chatDownloadAddedUnnamedToast(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.chat.toast.addedUnnamed",
            defaultValue: "Added ^[\(count) track](inflect: true) to the playlist",
            comment: "Toast summarising added downloads when the playlist's name could not be read"
        ))
    }

    // MARK: - The one guidance sentence

    /// Shown at most once per batch when the import gate refused the files.
    static let chatDownloadGateGuidanceToast = LocalizedStringResource(
        "app.downloads.chat.toast.gateGuidance",
        defaultValue: """
        Downloaded, but not added to your library, so nothing could be added to the \
        playlist. Turn on automatic import in Settings ▸ Downloads, or add that folder \
        in Settings ▸ Library.
        """,
        comment: "Toast shown when the import gate refused chat-initiated downloads, naming both fixes"
    )

    // MARK: - The single-fault sentences

    static let chatDownloadQueueFullToast = LocalizedStringResource(
        "app.downloads.chat.toast.queueFull",
        defaultValue: "The download queue is full, so these tracks won’t be added to the playlist.",
        comment: "Toast shown when the download queue or the registry was at its cap"
    )

    static let chatDownloadNoPlaylistToast = LocalizedStringResource(
        "app.downloads.chat.toast.noPlaylist",
        defaultValue: "That playlist was never created, so these downloads won’t be added to it.",
        comment: "Toast shown when the proposal a download was aimed at was discarded"
    )

    static let chatDownloadPlaylistMissingToast = LocalizedStringResource(
        "app.downloads.chat.toast.playlistMissing",
        defaultValue: "That playlist no longer exists, so the download wasn’t added to it.",
        comment: "Toast shown when the playlist a finished download was bound for has been deleted"
    )

    static let chatDownloadUnresolvedToast = LocalizedStringResource(
        "app.downloads.chat.toast.unresolved",
        defaultValue: "That track was already downloaded, but MacAMP couldn’t find it in your library.",
        comment: "Toast shown when a re-download resolved no library row to add to the playlist"
    )

    static let chatDownloadProfileChangedToast = LocalizedStringResource(
        "app.downloads.chat.toast.profileChanged",
        defaultValue: "You switched profiles, so this download wasn’t added to the playlist.",
        comment: "Toast shown when the profile that asked for a download is no longer the active one"
    )

    static let chatDownloadAbandonedToast = LocalizedStringResource(
        "app.downloads.chat.toast.abandoned",
        defaultValue: "That download didn’t finish, so it won’t be added to the playlist.",
        comment: "Toast shown when a download ended without producing a file to append"
    )

    static let chatDownloadAppendFailedToast = LocalizedStringResource(
        "app.downloads.chat.toast.appendFailed",
        defaultValue: "MacAMP downloaded that track but couldn’t add it to the playlist.",
        comment: "Toast shown when the playlist membership write itself failed"
    )

    static let chatDownloadImportFailedToast = LocalizedStringResource(
        "app.downloads.chat.toast.importFailed",
        defaultValue: "MacAMP downloaded that track but couldn’t find it in your library.",
        comment: "Toast shown when the scan ran but the downloaded file resolved to no library row"
    )
}
