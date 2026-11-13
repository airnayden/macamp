// One row of the Downloads History tab.
//
// ── THE FILE-EXISTENCE CHECK IS DELIBERATELY DONE AT RENDER ─────────────────
//
// `fileExists` is read in `body`, not carried on the record and not cached when the
// page loads. A history entry records where a file WENT; whether it is still there is a
// fact about the filesystem right now, and the listener can move or delete it at any
// moment — including between the page load and the click. A cached answer would offer
// Reveal in Finder for a file that is gone (Finder then does nothing at all, which
// reads as a broken button) or refuse it for a file that came back. The cost is one
// `stat` per visible row per body evaluation, which `List` already bounds by
// virtualization.
//
// There is NO filesystem watcher behind this, by design: a log of finished downloads is
// not a live view of a folder, and watching the destination would be a second FSEvents
// source over a directory MacAMP deliberately does not watch.
//
// ── NO THUMBNAIL, AND THAT IS A DECISION ────────────────────────────────────
//
// Queue rows show a 32×32 poster frame because the oEmbed decoration handed them a
// thumbnail URL. A history row has none — v17 stores no thumbnail column — and the only
// ways to get one back would be to invent an `i.ytimg.com` URL shape outside anything
// oEmbed answered (a new egress shape the downloader boundary exists to prevent) or to
// key the in-memory cache by video id, which would only ever hit for a video downloaded
// in this same session. The row is text-first instead, led by a container badge.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import ViewModels

/// One download attempt and its available actions.
struct DownloadsHistoryRow: View {
    let entry: DownloadHistoryRecord
    /// The row's index in the loaded window, from 0. Numbers its accessibility
    /// identifiers.
    let position: Int
    let onReveal: () -> Void
    let onRedownload: () -> Void
    let onDelete: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            identity
            Spacer(minLength: tokens.spacing.small)
            timestamp
            if entry.failureReason != nil {
                Button(action: onRedownload) {
                    Label { Text(MacAMPStrings.downloadsHistoryRetry) } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .help(Text(MacAMPStrings.downloadsHistoryRetry))
                .accessibilityIdentifier("downloads.history.row.\(position).retryButton")
            } else {
                DownloadsRowButton(
                    systemImage: "folder",
                    label: MacAMPStrings.downloadsHistoryReveal,
                    help: fileExists ? nil : MacAMPStrings.downloadsHistoryRevealMissing,
                    isEnabled: fileExists,
                    accessibilityID: "downloads.history.row.\(position).revealButton",
                    action: onReveal
                )
            }
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .contextMenu { menu }
    }
}

// MARK: - Row parts

private extension DownloadsHistoryRow {
    /// Fresh on every body evaluation — see the file header.
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: entry.filePath)
    }

    var identity: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.hairline * 2) {
            // The identifier sits on the TITLE text rather than the enclosing stack: an
            // identifier on a container that is not itself an accessibility element is
            // shadowed by its children, so XCUITest would never resolve it. Same
            // reasoning as `DownloadsRowLabel`.
            Text(verbatim: DownloadHistoryEntryFormat.displayTitle(
                title: entry.title,
                sourceURL: entry.sourceURL
            ))
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("downloads.history.row.\(position)")
            metaLine
            if let reason = entry.failureReason {
                Text(verbatim: reason)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .lineLimit(2)
                    .help(Text(verbatim: reason))
                    .accessibilityIdentifier("downloads.history.row.\(position).failureReason")
            }
        }
    }

    var metaLine: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            if let uploader = entry.uploader, !uploader.isEmpty {
                Text(verbatim: uploader)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
            Text(verbatim: badge)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .lineLimit(1)
        }
        .font(tokens.typography.caption.font)
    }

    /// `M4A · Best` — an untranslatable container token and the SAME quality name the
    /// Downloads preference pane offers, separated by punctuation. Composed here rather
    /// than held as a catalog key so neither half can drift from the pane the listener
    /// picked it in; an unknown stored quality degrades to the container alone.
    var badge: String {
        let container = DownloadHistoryEntryFormat.formatToken(entry.audioFormat)
        guard let quality = DownloadHistoryEntryFormat.quality(entry.audioQuality) else {
            return container
        }
        return "\(container) · \(String(localized: PreferencesStrings.downloadsQualityName(quality)))"
    }

    /// The relative phrase a listener reads, with the exact capture-local moment behind
    /// it as a tooltip — the consumer v17's `utcOffsetSeconds` column exists for.
    var timestamp: some View {
        let absolute = DownloadHistoryEntryFormat.absoluteTimestamp(
            downloadedAt: entry.downloadedAt,
            utcOffsetSeconds: entry.utcOffsetSeconds
        )
        return Text(verbatim: DownloadHistoryEntryFormat.relativeTimestamp(downloadedAt: entry.downloadedAt))
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .lineLimit(1)
            .help(entry.failureReason == nil
                ? Text(MacAMPStrings.downloadsHistoryDownloadedAt(absolute))
                : Text(verbatim: absolute))
    }
}

// MARK: - Context menu

private extension DownloadsHistoryRow {
    /// Context-menu buttons take neither `.help` nor `.pointingHandCursor()`: `NSMenu`
    /// rows never receive `.onHover`, and each visible label already names its action
    /// (the repo-wide context-menu exemption).
    @ViewBuilder
    var menu: some View {
        if entry.failureReason == nil {
            Button(action: onReveal) {
                Label { Text(MacAMPStrings.downloadsHistoryReveal) } icon: {
                    Image(systemName: "folder")
                }
            }
            .disabled(!fileExists)
            Button(action: onRedownload) {
                Label { Text(MacAMPStrings.downloadsHistoryRedownload) } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
        } else {
            Button(action: onRedownload) {
                Label { Text(MacAMPStrings.downloadsHistoryRetry) } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        Divider()
        // The one item whose consequence is not readable from its label: "Delete Entry"
        // could plausibly mean the audio file. `NSMenu` rows never receive `.onHover`,
        // so a tooltip is unavailable here — an accessibility hint is exactly the right
        // carrier, since it describes the RESULT of the action rather than its name.
        Button(role: .destructive, action: onDelete) {
            Label { Text(MacAMPStrings.downloadsHistoryDelete) } icon: {
                Image(systemName: "trash")
            }
        }
        .accessibilityHint(Text(MacAMPStrings.downloadsHistoryDeleteHelp))
    }
}
