// Downloads queue pane copy plus the row-state caption map. Split from
// `DownloadsStrings.swift` for the SwiftLint file-length budget; see that file's
// header for why the shell's Downloads copy extends `MacAMPStrings`.
import Foundation
import Services

extension MacAMPStrings {
    // MARK: - Pane chrome

    static let downloadsQueueEmptyTitle = LocalizedStringResource(
        "app.downloads.queue.emptyTitle",
        defaultValue: "Nothing Downloading",
        comment: "Empty-state title on the Downloads pane when the queue holds no work"
    )
    static let downloadsQueueEmptyMessage = LocalizedStringResource(
        "app.downloads.queue.emptyMessage",
        defaultValue: "Paste a YouTube link to download its audio",
        comment: "Empty-state message on the Downloads pane when the queue holds no work"
    )
    static let downloadsQueueUnavailableTitle = LocalizedStringResource(
        "app.downloads.queue.unavailableTitle",
        defaultValue: "Downloads Are Starting Up",
        comment: "Placeholder title shown before the download queue has finished being built"
    )
    static let downloadsQueueUnavailableMessage = LocalizedStringResource(
        "app.downloads.queue.unavailableMessage",
        defaultValue: "This pane is ready a moment after MacAMP finishes launching",
        comment: "Placeholder message shown before the download queue has finished being built"
    )
    static let downloadsQueueDownloadingHeader = LocalizedStringResource(
        "app.downloads.queue.downloadingHeader",
        defaultValue: "Downloading",
        comment: "Section header above the download that is currently transferring"
    )
    static let downloadsQueuePendingHeader = LocalizedStringResource(
        "app.downloads.queue.pendingHeader",
        defaultValue: "Up Next",
        comment: "Section header above the downloads waiting their turn"
    )
    static let downloadsQueuePause = LocalizedStringResource(
        "app.downloads.queue.pause",
        defaultValue: "Pause Downloads",
        comment: "Header button pausing the download driver"
    )
    static let downloadsQueueResume = LocalizedStringResource(
        "app.downloads.queue.resume",
        defaultValue: "Resume Downloads",
        comment: "Header button resuming the download driver"
    )
    static let downloadsQueuePausedNotice = LocalizedStringResource(
        "app.downloads.queue.pausedNotice",
        defaultValue: "No new downloads will start",
        comment: """
        Header notice shown while the download queue is paused. It says only that new \
        work is held back, because transfers already running are not interrupted
        """
    )
    static let downloadsQueueCancel = LocalizedStringResource(
        "app.downloads.queue.cancel",
        defaultValue: "Cancel Download",
        comment: "Row button cancelling the download that is currently transferring"
    )
    static let downloadsQueueRemove = LocalizedStringResource(
        "app.downloads.queue.remove",
        defaultValue: "Remove",
        comment: "Context-menu item removing a waiting download from the queue"
    )

    static func downloadsQueueOverflow(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.queue.overflow",
            defaultValue: "^[\(count) more download](inflect: true) waiting",
            comment: "Row reporting how many queued downloads sit past the pane's display window"
        ))
    }

    // MARK: - Row-state captions

    static let downloadsStateQueued = LocalizedStringResource(
        "app.downloads.state.queued",
        defaultValue: "Waiting",
        comment: "Row caption for a download that has not started yet"
    )
    static let downloadsStateFetchingMetadata = LocalizedStringResource(
        "app.downloads.state.fetchingMetadata",
        defaultValue: "Reading video details…",
        comment: "Row caption while the engine prefetches a video's title and duration"
    )
    static let downloadsStateDownloading = LocalizedStringResource(
        "app.downloads.state.downloading",
        defaultValue: "Downloading…",
        comment: "Row caption while bytes are transferring"
    )
    static let downloadsStatePostProcessing = LocalizedStringResource(
        "app.downloads.state.postProcessing",
        defaultValue: "Converting audio…",
        comment: "Row caption while the engine extracts and tags the finished transfer"
    )
    static let downloadsStateConvertingM4A = LocalizedStringResource(
        "app.downloads.state.converting.m4a",
        defaultValue: "Converting to M4A…",
        comment: "Row caption while the engine converts the finished transfer to an M4A file"
    )
    static let downloadsStateConvertingMP3 = LocalizedStringResource(
        "app.downloads.state.converting.mp3",
        defaultValue: "Converting to MP3…",
        comment: "Row caption while the engine converts the finished transfer to an MP3 file"
    )
    static let downloadsStateConvertingOpus = LocalizedStringResource(
        "app.downloads.state.converting.opus",
        defaultValue: "Converting to Opus…",
        comment: "Row caption while the engine converts the finished transfer to an Opus file"
    )
    static let downloadsStateConvertingFLAC = LocalizedStringResource(
        "app.downloads.state.converting.flac",
        defaultValue: "Converting to FLAC…",
        comment: "Row caption while the engine converts the finished transfer to a FLAC file"
    )
    static let downloadsStateFinished = LocalizedStringResource(
        "app.downloads.state.finished",
        defaultValue: "Finished",
        comment: "Row caption for a download whose file has landed"
    )
    static let downloadsStateCancelled = LocalizedStringResource(
        "app.downloads.state.cancelled",
        defaultValue: "Cancelled",
        comment: "Row caption for a download that was stopped before it finished"
    )
}

/// Maps a ``DownloadState`` to the sentence a row shows beneath its title.
///
/// A caseless enum rather than a `DownloadState` extension: the state type lives in
/// PlayerCore `Services`, and this copy is the macOS shell's. A failure resolves to
/// ``DownloadError/message`` so the ladder's own sentences are never restated here.
enum DownloadStateCaption {
    /// The caption for `state`, or the waiting caption when there is no state yet.
    ///
    /// `format` names the container the row is being converted INTO, and is used by the
    /// post-processing phase alone. It is deliberately NOT derived from the state: the
    /// caption must read the same whether or not ffmpeg happens to be emitting progress.
    static func text(for state: DownloadState?, format: DownloadFormat? = nil) -> LocalizedStringResource {
        guard let state else { return MacAMPStrings.downloadsStateQueued }
        switch state {
        case .queued: return MacAMPStrings.downloadsStateQueued
        case .fetchingMetadata: return MacAMPStrings.downloadsStateFetchingMetadata
        case .downloading: return MacAMPStrings.downloadsStateDownloading
        case .postProcessing: return convertingText(for: format)
        case .finished: return MacAMPStrings.downloadsStateFinished
        case .cancelled: return MacAMPStrings.downloadsStateCancelled
        case let .failed(error): return error.message
        }
    }

    /// The staged label for the whole post-processing phase, named after the container
    /// being produced — or the generic one before the driver has stamped a format.
    ///
    /// # This must not depend on the fraction, and that is the point
    /// `.postProcessing` carries an optional fraction that legitimately goes
    /// `nil → value → nil` within one phase: `nil` until ffmpeg emits its first block,
    /// the real figure while blocks arrive, and `nil` again from `progress=end`, because
    /// the embed and metadata passes still have to run. Only the BAR may follow that —
    /// a caption that switched with it would flicker between two sentences two or three
    /// times per download, which reads as a fault rather than as precision. A remuxed
    /// m4a, an unknown duration and a conversion too fast to sample therefore all sit
    /// under exactly the same honest label.
    private static func convertingText(for format: DownloadFormat?) -> LocalizedStringResource {
        guard let format else { return MacAMPStrings.downloadsStatePostProcessing }
        switch format.audioFormat {
        case .m4a: return MacAMPStrings.downloadsStateConvertingM4A
        case .mp3: return MacAMPStrings.downloadsStateConvertingMP3
        case .opus: return MacAMPStrings.downloadsStateConvertingOpus
        case .flac: return MacAMPStrings.downloadsStateConvertingFLAC
        }
    }

    /// The caption for an ACTIVE row — its real phase, always.
    ///
    /// `isPaused` is accepted and DELIBERATELY IGNORED. It used to override the caption
    /// with "Paused", which was false: pausing stops the queue picking up new work and
    /// leaves running transfers alone, so the row went on downloading underneath a
    /// caption claiming it had stopped — a lie the listener could watch move. The paused
    /// fact is now stated once, by `DownloadsQueueView.pausedNotice`, in the terms that
    /// are actually true ("No new downloads will start").
    ///
    /// The parameter survives rather than being deleted so the call site still passes
    /// the flag and `DownloadsQueueCaptionTests` can keep asserting that passing `true`
    /// changes nothing — a reintroduced override would fail a test instead of shipping.
    static func currentText(
        for state: DownloadState?,
        format: DownloadFormat? = nil,
        isPaused _: Bool
    ) -> LocalizedStringResource {
        text(for: state, format: format)
    }
}
