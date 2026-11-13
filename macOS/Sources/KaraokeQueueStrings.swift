// Karaoke Queue copy, kept out of `MacAMPStrings.swift` so that file stays within
// the SwiftLint type-body-length / file-length budgets. These remain `MacAMPStrings`
// members (referenced as `MacAMPStrings.sidebarKaraokeQueue` etc.) via this extension.
import Foundation

extension MacAMPStrings {
    static let sidebarKaraokeQueue = LocalizedStringResource(
        "app.sidebar.karaokeQueue",
        defaultValue: "Karaoke Queue",
        comment: "Sidebar item and pane title for the karaoke render queue (in-flight + pending renders)"
    )
    static let karaokeQueueNowRenderingHeader = LocalizedStringResource(
        "app.karaoke.queue.nowRendering",
        defaultValue: "Now Rendering",
        comment: "Section header above the karaoke track currently being rendered"
    )
    static let karaokeQueuePendingHeader = LocalizedStringResource(
        "app.karaoke.queue.pending",
        defaultValue: "Up Next",
        comment: "Section header above the karaoke tracks waiting to be rendered"
    )
    static let karaokeQueueRenderingCaption = LocalizedStringResource(
        "app.karaoke.queue.renderingCaption",
        defaultValue: "Rendering…",
        comment: "Caption under the in-flight karaoke render's progress bar"
    )
    static let karaokeQueuePause = LocalizedStringResource(
        "app.karaoke.queue.pause",
        defaultValue: "Pause rendering",
        comment: "Tooltip and accessibility label for the button that pauses karaoke rendering"
    )
    static let karaokeQueueResume = LocalizedStringResource(
        "app.karaoke.queue.resume",
        defaultValue: "Resume rendering",
        comment: "Tooltip and accessibility label for the button that resumes karaoke rendering"
    )
    static let karaokeQueueStartNow = LocalizedStringResource(
        "app.karaoke.queue.startNow",
        defaultValue: "Start now",
        comment: "Tooltip and accessibility label for the button that immediately starts rendering a pending karaoke track, preempting the current render"
    )
    static let karaokeQueueStop = LocalizedStringResource(
        "app.karaoke.queue.stop",
        defaultValue: "Stop",
        comment: "Tooltip and accessibility label for the button that stops the in-flight karaoke render and pauses the queue"
    )
    static let karaokeQueueRemove = LocalizedStringResource(
        "app.karaoke.queue.remove",
        defaultValue: "Remove from Queue",
        comment: "Context-menu command that removes a pending track from the karaoke render queue"
    )
    static let karaokeQueueEmptyTitle = LocalizedStringResource(
        "app.karaoke.queue.emptyTitle",
        defaultValue: "Nothing Queued",
        comment: "Empty-state title on the karaoke queue when no renders are pending or in flight"
    )
    static let karaokeQueueEmptyMessage = LocalizedStringResource(
        "app.karaoke.queue.emptyMessage",
        defaultValue: "Create a karaoke version of a song to see it render here.",
        comment: "Empty-state message on the karaoke queue when no renders are pending or in flight"
    )
    static let karaokeVersionReadyToast = LocalizedStringResource(
        "app.karaoke.toast.ready",
        defaultValue: "Karaoke version ready",
        comment: "Toast shown when a single track's karaoke version finishes rendering"
    )
    static let karaokeAlreadyAvailableToast = LocalizedStringResource(
        "app.karaoke.toast.alreadyAvailable",
        defaultValue: "Karaoke version already available",
        comment: "Toast shown when a requested karaoke version is already present in the instrumental cache"
    )
    static let karaokeVersionFailedToast = LocalizedStringResource(
        "app.karaoke.toast.failed",
        defaultValue: "Couldn’t create karaoke version",
        comment: "Toast shown when a single track's karaoke render fails"
    )
    static let karaokeQueueFinishedToast = LocalizedStringResource(
        "app.karaoke.toast.allFinished",
        defaultValue: "All karaoke versions finished",
        comment: "Toast shown when the karaoke render queue drains (the last pending render completes)"
    )
    static let karaokeEnqueuedToast = LocalizedStringResource(
        "app.karaoke.toast.enqueued",
        defaultValue: "Added to karaoke queue",
        comment: "Toast shown when a track is added to the karaoke render queue"
    )
}
