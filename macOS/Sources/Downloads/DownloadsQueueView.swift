// DownloadsQueueView — the queue list behind the `.downloads` sidebar destination: the
// videos transferring right now, each with its own determinate progress bar and its own
// cancel button, the videos waiting behind them (drag to reorder, right-click to
// remove), and one pause/resume control over the whole driver.
//
// PERFORMANCE (SKILL macOS UI perf rule 3). Several transfers run at once and each
// reports progress a few times a second. This body therefore reads MEMBERSHIP only —
// `activeRows` (the array, never a leaf's state), `pendingRows`, `pendingOverflow`,
// `isPaused`, all of which change on a queue MUTATION. Every live read happens inside
// ``DownloadsActiveRow`` / ``DownloadsProgressBar``, one instance per row, each bound to
// ONE ``DownloadRowLeaf``. A tick therefore re-renders one row and leaves its siblings
// alone — the claim `macOS/Tests/DownloadsRowInvalidationTests.swift` measures.
//
// PAUSE HONESTY. Pausing stops the queue starting anything NEW; rows already in flight
// run to completion untouched. So an active row always shows its REAL phase, and the
// paused fact is stated once, in the header, by ``pausedNotice``. Relabelling a running
// transfer's caption "Paused" was a lie the listener could watch move.
//
// Nothing here is timer-driven: every redraw is caused by a seam the composition root
// pushed into ``DownloadQueueStore``.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import DesignSystem
import Services
import SwiftUI
import ViewModels

struct DownloadsQueueView: View {
    let model: DownloadsViewModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// How many waiting rows the pending list names individually. A thousand-row queue
    /// is bounded by the store's display window; this bounds what one screen tries to
    /// lay out inside that window.
    private static let visiblePendingLimit = DownloadQueueStore.displayWindowLimit

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            queueBody
        }
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
    }
}

// MARK: - Chrome

private extension DownloadsQueueView {
    var header: some View {
        HStack(spacing: tokens.spacing.small) {
            if model.isPaused { pausedNotice }
            Spacer(minLength: 0)
            pauseResumeButton
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    /// The ONE place a paused queue is stated.
    ///
    /// It says what pause actually does — stop new work — rather than implying the
    /// running transfers stopped, because they did not (see the file header).
    var pausedNotice: some View {
        Label {
            Text(MacAMPStrings.downloadsQueuePausedNotice)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .lineLimit(1)
        } icon: {
            Image(systemName: "pause.circle")
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
        }
        .accessibilityIdentifier("downloads.queue.pausedNotice")
    }

    /// One state-aware transport control over the whole driver, derived purely from
    /// the store so it always reflects reality: working → pause, otherwise → resume,
    /// and disabled (greyed, no hand cursor) while the queue holds no work at all.
    @ViewBuilder
    var pauseResumeButton: some View {
        let working = model.isWorking
        let label = working ? MacAMPStrings.downloadsQueuePause : MacAMPStrings.downloadsQueueResume
        let button = Button { model.togglePaused() } label: {
            Image(systemName: working ? "pause.circle" : "play.circle")
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(
                    model.isEmpty
                        ? tokens.colors.textDisabled.resolve(scheme)
                        : tokens.colors.accent.resolve(scheme)
                )
        }
        .buttonStyle(.plain)
        .disabled(model.isEmpty)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("downloads.queue.pauseButton")

        if model.isEmpty {
            button
        } else {
            button.pointingHandCursor()
        }
    }

    @ViewBuilder
    var queueBody: some View {
        if model.isEmpty {
            StateView(
                systemImage: "arrow.down.circle",
                title: MacAMPStrings.downloadsQueueEmptyTitle,
                message: MacAMPStrings.downloadsQueueEmptyMessage
            )
            .synthwaveEmptyBackground()
        } else {
            queueList
        }
    }

    var queueList: some View {
        List {
            if !model.activeRows.isEmpty {
                Section {
                    activeRows
                } header: {
                    Text(MacAMPStrings.downloadsQueueDownloadingHeader)
                }
            }
            if !model.pendingRows.isEmpty {
                Section {
                    pendingRows
                } header: {
                    Text(MacAMPStrings.downloadsQueuePendingHeader)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// One row per in-flight transfer, each handed the leaf it — and only it — observes.
    ///
    /// `position` numbers the ACTIVE section from 0 and is independent of the pending
    /// section's own numbering; the two families are told apart by their identifier
    /// prefixes (`downloads.queue.activeRow.<n>` vs `downloads.queue.row.<n>`).
    var activeRows: some View {
        ForEach(Array(model.activeRows.enumerated()), id: \.element.id) { index, leaf in
            DownloadsActiveRow(leaf: leaf, position: index, isPaused: model.isPaused) {
                model.cancel(leaf.id)
            }
        }
    }

    @ViewBuilder
    var pendingRows: some View {
        let rows = Array(model.pendingRows.prefix(Self.visiblePendingLimit))
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            pendingRow(row, position: index)
        }
        .onMove { source, destination in
            movePending(from: source, to: destination)
        }
        if model.pendingOverflow > 0 {
            Text(verbatim: MacAMPStrings.downloadsQueueOverflow(model.pendingOverflow))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityIdentifier("downloads.queue.overflow")
        }
    }
}

// MARK: - Pending rows

private extension DownloadsQueueView {
    /// `position` is the row's index within the PENDING section, so position 0 is the
    /// next video to start — not the one currently transferring.
    func pendingRow(_ row: DownloadRow, position: Int) -> some View {
        HStack(spacing: tokens.spacing.small) {
            DownloadsRowLabel(
                title: row.title,
                uploader: row.uploader,
                thumbnailURL: row.thumbnailURL,
                accessibilityID: "downloads.queue.row.\(position)"
            )
            Spacer(minLength: 0)
            Text(DownloadStateCaption.text(for: row.state))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .lineLimit(1)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .contextMenu {
            Button(role: .destructive) {
                model.remove(row.id)
            } label: {
                Label {
                    Text(MacAMPStrings.downloadsQueueRemove)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    /// Maps SwiftUI's insert-BEFORE `.onMove` offset onto the queue's final-position
    /// index and forwards the moved row's id. The queue reorders its own pending array
    /// and re-publishes the snapshot, so the list settles through the store rather
    /// than being spliced here.
    func movePending(from source: IndexSet, to destination: Int) {
        let rows = model.pendingRows
        guard let sourceIndex = source.first, sourceIndex < rows.count else { return }
        let finalIndex = destination > sourceIndex ? destination - 1 : destination
        model.move(rows[sourceIndex].id, to: finalIndex)
    }
}
