// DownloadsPasteSheet — the one way a YouTube link enters MacAMP.
//
// A multi-line editor, an Add button, and an INLINE report: how many links were
// queued, how many were already there, and — listed by name — which pasted lines were
// not YouTube links at all. Nothing is dropped silently, which matters more here than
// it looks: canonical-id dedup is what stops a re-download from failing ungracefully
// (a second attempt into a non-empty destination exits 1 at yt-dlp's metadata
// post-processor, not with the friendly "already downloaded" row), so telling the
// person a link was a duplicate is load-bearing feedback rather than a nicety.
//
// A pasted PLAYLIST is expanded but HELD by the queue. This sheet shows the REAL video
// count and asks — and when the expansion hit
// ``DownloadQueueLimits/maxPlaylistExpansion`` it says so and offers "Add First N"
// rather than truncating quietly. Confirming calls `confirmPlaylist(_:)` with the
// token from the outcome; a token the queue has already discarded answers with the
// zero outcome, which renders as "0 added" instead of an error.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import DesignSystem
import Services
import SwiftUI
import ViewModels

struct DownloadsPasteSheet: View {
    let model: DownloadsViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var text = ""
    @State private var result: DownloadPasteResult?
    @State private var pendingPlaylist: EnqueueOutcome.PendingPlaylist?
    @State private var confirmationSummary: String?
    @State private var isBusy = false
    /// How many of the last paste's links had been downloaded before — ADVISORY, and
    /// therefore separate from ``result``: it lands after the report is already on
    /// screen, and `0` (no history, nothing matched, or the lookup failed) renders
    /// nothing at all rather than a "0 of these" line.
    @State private var previouslyDownloaded = 0

    /// How many refused lines are named individually before the list summarizes the
    /// rest. Enough to recognize a mistake, not enough to turn the sheet into a log.
    private static let namedSkippedLimit = 5
    private static let sheetWidth: CGFloat = 460
    private static let editorMinHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            heading
            editor
            reportSection
            playlistSection
            Divider()
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: Self.sheetWidth)
        .background(tokens.colors.surface.resolve(scheme))
    }
}

// MARK: - Chrome

private extension DownloadsPasteSheet {
    var heading: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(MacAMPStrings.downloadsPasteTitle)
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier("downloads.pasteSheet")
            Text(MacAMPStrings.downloadsPasteMessage)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var editor: some View {
        TextEditor(text: $text)
            .font(tokens.typography.callout.font)
            .scrollContentBackground(.hidden)
            .padding(tokens.spacing.xSmall)
            .frame(minHeight: Self.editorMinHeight)
            .background(
                RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                    .fill(tokens.colors.surfaceRaised.resolve(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                    .stroke(tokens.colors.separator.resolve(scheme), lineWidth: 1)
            )
            .disabled(isBusy)
            .accessibilityLabel(Text(MacAMPStrings.downloadsPasteEditorLabel))
            .accessibilityIdentifier("downloads.pasteSheet.editor")
    }

    /// A spinner plus one sentence, present only while a spawn is in flight.
    ///
    /// Both actions this sheet raises shell out to `yt-dlp`, and that binary unpacks
    /// itself before it does any work (~12.6 s measured), so the wait is long enough
    /// that two greyed buttons and no other change read as a hang.
    @ViewBuilder
    var busyIndicator: some View {
        if isBusy {
            HStack(spacing: tokens.spacing.xSmall) {
                ProgressView()
                    .controlSize(.small)
                Text(MacAMPStrings.downloadsPasteWorking)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(MacAMPStrings.downloadsPasteWorking))
            .accessibilityIdentifier("downloads.pasteSheet.busy")
        }
    }

    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            busyIndicator
            Spacer()
            Button { dismiss() } label: {
                Text(result == nil ? MacAMPStrings.downloadsPasteCancel : MacAMPStrings.downloadsPasteDone)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("downloads.pasteSheet.dismissButton")
            .pointingHandCursor()

            Button { submit() } label: {
                Text(MacAMPStrings.downloadsPasteAdd)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(Text(MacAMPStrings.downloadsPasteAddHelp))
            .accessibilityLabel(Text(MacAMPStrings.downloadsPasteAdd))
            .accessibilityIdentifier("downloads.pasteSheet.addButton")
            .pointingHandCursor()
        }
    }
}

// MARK: - Report

private extension DownloadsPasteSheet {
    var reportSection: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            if let summary = confirmationSummary ?? result.flatMap(DownloadsPasteSummary.text(for:)) {
                Text(verbatim: summary)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("downloads.pasteSheet.report")
            }
            previouslyDownloadedHint
            if let lines = result?.skippedLines, !lines.isEmpty {
                skippedList(lines)
            }
        }
    }

    /// One inline advisory line, and never a badge on any row.
    ///
    /// It states a fact and asks for nothing: the links were queued regardless, and a
    /// video downloaded before is downloaded again if the person wants it again.
    @ViewBuilder
    var previouslyDownloadedHint: some View {
        if previouslyDownloaded > 0 {
            Text(verbatim: MacAMPStrings.downloadsPastePreviouslyDownloadedReport(previouslyDownloaded))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("downloads.pasteSheet.previouslyDownloaded")
        }
    }

    func skippedList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.hairline * 2) {
            Text(MacAMPStrings.downloadsPasteSkippedHeader)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .accessibilityIdentifier("downloads.pasteSheet.skipped")
            ForEach(Array(lines.prefix(Self.namedSkippedLimit).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if lines.count > Self.namedSkippedLimit {
                Text(verbatim: MacAMPStrings.downloadsPasteSkippedMore(lines.count - Self.namedSkippedLimit))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
        }
    }
}

// MARK: - Playlist confirmation

private extension DownloadsPasteSheet {
    @ViewBuilder
    var playlistSection: some View {
        if let playlist = pendingPlaylist {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(MacAMPStrings.downloadsPlaylistTitle)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier("downloads.pasteSheet.playlist")
                Text(verbatim: playlist.capped
                    ? MacAMPStrings.downloadsPlaylistCapped(playlist.count)
                    : MacAMPStrings.downloadsPlaylistCount(playlist.count))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                playlistActions(playlist)
            }
            .padding(tokens.spacing.small)
            .background(
                RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                    .fill(tokens.colors.accentMuted.resolve(scheme))
            )
        }
    }

    func playlistActions(_ playlist: EnqueueOutcome.PendingPlaylist) -> some View {
        HStack(spacing: tokens.spacing.small) {
            Button { pendingPlaylist = nil } label: {
                Text(MacAMPStrings.downloadsPlaylistSkip)
            }
            .disabled(isBusy)
            .help(Text(MacAMPStrings.downloadsPlaylistSkipHelp))
            .accessibilityLabel(Text(MacAMPStrings.downloadsPlaylistSkip))
            .accessibilityIdentifier("downloads.pasteSheet.playlistSkipButton")
            .pointingHandCursor()

            Button { confirm(playlist) } label: {
                Text(verbatim: playlist.capped
                    ? MacAMPStrings.downloadsPlaylistAddCapped(playlist.count)
                    : MacAMPStrings.downloadsPlaylistAdd(playlist.count))
            }
            .disabled(isBusy)
            .accessibilityIdentifier("downloads.pasteSheet.playlistAddButton")
            .pointingHandCursor()
        }
    }
}

// MARK: - Actions

private extension DownloadsPasteSheet {
    /// Parses and enqueues, then clears the editor so a second Add cannot re-submit
    /// the same block (which would report every link as a duplicate).
    func submit() {
        guard !isBusy else { return }
        isBusy = true
        confirmationSummary = nil
        previouslyDownloaded = 0
        let pasted = text
        Task {
            let outcome = await model.submit(pastedText: pasted)
            result = outcome
            pendingPlaylist = outcome.report.pendingPlaylist
            if !outcome.report.isEmpty || outcome.report.needsConfirmation { text = "" }
            isBusy = false
            await noteHistory(for: pasted)
        }
    }

    /// Asks the history log about the paste that just finished.
    ///
    /// Deliberately the LAST thing the submit task does, after `result` is published and
    /// the spinner is down: the enqueue's outcome is final and on screen by the time a
    /// single database statement is even issued, so nothing about the paste — its speed,
    /// its report, or which links were accepted — depends on this answering, or on its
    /// answering at all.
    ///
    /// The paste is re-parsed rather than threaded through ``DownloadPasteResult``
    /// because that value is the enqueue's report and must stay byte-identical whether
    /// or not this hint exists. `parse` is pure Foundation arithmetic over a short
    /// string, which is a far smaller cost than widening a shared value type.
    func noteHistory(for pasted: String) async {
        let urls = DownloadPasteInput.parse(pasted).urls
        guard !urls.isEmpty else { return }
        previouslyDownloaded = await model.previouslyDownloadedCount(in: urls)
    }

    /// Commits the held expansion. A stale token answers with the zero outcome, which
    /// is reported as "0 added" — an expired confirmation is not an error.
    func confirm(_ playlist: EnqueueOutcome.PendingPlaylist) {
        guard !isBusy else { return }
        isBusy = true
        previouslyDownloaded = 0
        Task {
            let report = await model.confirmPlaylist(playlist.token)
            pendingPlaylist = nil
            confirmationSummary = report.added > 0
                ? MacAMPStrings.downloadsPasteAddedReport(report.added)
                : String(localized: MacAMPStrings.downloadsPlaylistExpiredReport)
            isBusy = false
        }
    }
}

// MARK: - Summary copy

/// Assembles the one-line paste report from the counts that are non-zero.
///
/// Returns `nil` — rather than an empty string — when there is nothing to say: a paste
/// that ONLY held a playlist has its whole story told by the confirmation step below,
/// and a redundant "0 links added" above it would contradict the button that is about
/// to add several hundred.
private enum DownloadsPasteSummary {
    static func text(for result: DownloadPasteResult) -> String? {
        var parts: [String] = []
        if result.linkCount > 0 {
            parts.append(MacAMPStrings.downloadsPasteLinksReport(result.linkCount))
        }
        if result.report.duplicatesDropped > 0 {
            parts.append(MacAMPStrings.downloadsPasteDuplicatesReport(result.report.duplicatesDropped))
        }
        if !result.skippedLines.isEmpty {
            parts.append(MacAMPStrings.downloadsPasteSkippedReport(result.skippedLines.count))
        }
        if parts.isEmpty {
            return result.report.needsConfirmation
                ? nil
                : String(localized: MacAMPStrings.downloadsPasteNothingReport)
        }
        return parts.joined(separator: ", ")
    }
}
