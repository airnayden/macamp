// DownloadsHistoryView — completed and failed downloads, newest first, paged
// through ``DownloadHistoryViewModel``.
//
// ── NOTHING ON THIS SCREEN DELETES A FILE ───────────────────────────────────
//
// Delete Entry removes ONE row. Clear History removes ALL rows. Neither touches the
// audio on disk, and there is no code path here that could: this view owns no write to
// the filesystem, and the only `NSWorkspace` call it makes REVEALS a file in the Finder.
// The asymmetric confirmation follows from that — Delete Entry asks nothing, because
// forgetting one line of a log is not destructive and friction would be theatre, while
// Clear History does ask, because forgetting the whole log at once is not recoverable
// even though the files are.
//
// ── RE-DOWNLOAD GOES THROUGH THE ORDINARY PASTE PATH ────────────────────────
//
// It hands the entry's `sourceURL` to the same `enqueue(urls:)` a paste calls, so the
// canonical-id dedup, the playlist handling and the destination probe all behave exactly
// as they do for a typed link. There is no history-specific enqueue, which is why
// re-downloading something already queued quietly does nothing instead of queueing a
// duplicate that would race for one output path.
//
// ── THE WINDOW RELOADS EACH TIME THE TAB IS SHOWN ───────────────────────────
//
// Reload when the tab opens and after the recorder commits a new entry.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import AppKit
import DesignSystem
import Foundation
import os
import Persistence
import SwiftUI
import ViewModels

/// The list of download attempts, with reveal, retry, and forget actions.
struct DownloadsHistoryView: View {
    let model: DownloadHistoryViewModel
    /// Queues one link through the ordinary paste path and shows the listener where it
    /// went. Supplied by the container, which owns the tab selection.
    let revision: Int
    let onRedownload: (DownloadHistoryRecord) -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var confirmsClear = false

    private static let log = Logger(subsystem: "si.macamp.MacAMP", category: "downloads.history")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .task(id: revision) { await load() }
        .confirmationDialog(
            Text(MacAMPStrings.downloadsHistoryClearConfirmTitle),
            isPresented: $confirmsClear
        ) {
            Button(role: .destructive, action: clear) {
                Text(MacAMPStrings.downloadsHistoryClearConfirmAction)
            }
            .accessibilityIdentifier("downloads.history.clearConfirm")
            Button(role: .cancel) {} label: {
                Text(MacAMPStrings.downloadsHistoryClearCancel)
            }
            .accessibilityIdentifier("downloads.history.clearCancel")
        } message: {
            Text(MacAMPStrings.downloadsHistoryClearConfirmMessage)
        }
    }
}

// MARK: - Chrome

private extension DownloadsHistoryView {
    var header: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer(minLength: 0)
            clearButton
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    /// Inert on an empty log, and greyed rather than hidden so the control keeps its
    /// place — and, per the interaction standards, takes no hand cursor while inert.
    @ViewBuilder
    var clearButton: some View {
        let isEmpty = model.entries.isEmpty
        let button = Button { confirmsClear = true } label: {
            Label {
                Text(MacAMPStrings.downloadsHistoryClear)
                    .font(tokens.typography.caption.font)
            } icon: {
                Image(systemName: "trash")
            }
            .foregroundStyle(
                isEmpty
                    ? tokens.colors.textDisabled.resolve(scheme)
                    : tokens.colors.accent.resolve(scheme)
            )
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .help(Text(MacAMPStrings.downloadsHistoryClearHelp))
        .accessibilityLabel(Text(MacAMPStrings.downloadsHistoryClear))
        .accessibilityIdentifier("downloads.history.clearButton")

        if isEmpty {
            button
        } else {
            button.pointingHandCursor()
        }
    }

    @ViewBuilder
    var content: some View {
        if !model.entries.isEmpty {
            historyList
        } else if !model.hasLoaded {
            StateView.loading()
                .synthwaveEmptyBackground()
        } else {
            StateView(
                systemImage: "clock.arrow.circlepath",
                title: MacAMPStrings.downloadsHistoryEmptyTitle,
                message: MacAMPStrings.downloadsHistoryEmptyMessage
            )
            .synthwaveEmptyBackground()
        }
    }

    /// Rows are keyed by the entry's own id, never by video id or path: a re-download
    /// appends a row sharing both with an earlier one, and either of those as an
    /// identity would collapse two real entries into one.
    var historyList: some View {
        List {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                DownloadsHistoryRow(
                    entry: entry,
                    position: index,
                    onReveal: { reveal(entry) },
                    onRedownload: { onRedownload(entry) },
                    onDelete: { delete(entry) }
                )
                .onAppear { paginate(at: index) }
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("downloads.history.list")
    }
}

// MARK: - Loading + actions

private extension DownloadsHistoryView {
    func load() async {
        do {
            try await model.loadInitial()
        } catch {
            Self.log.error("download history could not be read: \(error.localizedDescription, privacy: .public)")
        }
    }

    func paginate(at index: Int) {
        guard model.shouldPaginate(at: index) else { return }
        Task { try? await model.loadMore() }
    }

    /// Opens a Finder window with the file selected. Safe to call for a path that
    /// vanished a moment ago — the control is disabled for a missing file, and
    /// `activateFileViewerSelecting` simply does nothing for one that is gone.
    ///
    /// The verb is `activate…`, not `active…`: the misspelling compiles nowhere, which
    /// is the only reason it was caught rather than shipped as a dead button.
    func reveal(_ entry: DownloadHistoryRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
    }

    /// No confirmation: the row is a line in a log and the file it names is untouched.
    func delete(_ entry: DownloadHistoryRecord) {
        Task {
            do {
                try await model.remove(id: entry.id)
            } catch {
                Self.log.error("history entry could not be removed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clear() {
        Task {
            do {
                try await model.clearAll()
            } catch {
                Self.log.error("history could not be cleared: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
