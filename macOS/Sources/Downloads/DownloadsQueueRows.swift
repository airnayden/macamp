// Download-queue row views. Split from `DownloadsQueueView.swift` for the SwiftLint
// 400-line file budget (the `PlaylistDetailRows.swift` precedent), and kept in
// `macOS/Sources/Downloads` so both the downloader-boundary and localization gates
// still scan it.
//
// ── EVERY LIVE READ IS IN HERE, ONE ROW AT A TIME ────────────────────────────
//
// ``DownloadsActiveRow`` and ``DownloadsProgressBar`` are the only views that read a
// ``DownloadRowLeaf``'s live `state`, and each instance reads exactly ONE leaf. That is
// what confines a progress sample's invalidation to the row it belongs to instead of
// every bar on screen (SKILL macOS UI perf rule 3) — the whole reason the leaf exists.
// A read of anything queue-WIDE here (the store, the view model, a map of states) would
// undo it silently, so neither type is given either one: the row receives its leaf, its
// position, and a cancel closure, and that is all it can see.
//
// These types are internal rather than `private` so
// `macOS/Tests/DownloadsRowInvalidationTests.swift` can host three of them directly and
// count body evaluations without standing up a whole queue pane.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import DesignSystem
import Foundation
import Services
import SwiftUI
import ViewModels

/// One in-flight download: its title, a cancel button that stops only this transfer,
/// and its own determinate progress bar.
struct DownloadsActiveRow: View {
    let leaf: DownloadRowLeaf
    /// The row's index within the ACTIVE section, from 0. Numbers this row's
    /// accessibility identifiers and is unrelated to the pending section's numbering.
    let position: Int
    /// Whether the driver is paused. Threaded in as a plain value (it changes on a
    /// queue mutation, never on a tick) and deliberately does NOT rewrite this row's
    /// caption — see ``DownloadStateCaption/currentText(for:isPaused:)``.
    let isPaused: Bool
    let onCancel: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.downloadsRowBodyProbe) private var bodyProbe

    var body: some View {
        // `nil` in the shipping app; a test injects a recorder to count how many bodies
        // one leaf's tick actually re-evaluated. Same idiom as `Self._printChanges()`,
        // which is likewise called for its effect alone. This body reads only the
        // descriptive fields, so a tick must leave it alone entirely.
        _ = bodyProbe?(.row, leaf.id)
        return VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            HStack(spacing: tokens.spacing.small) {
                DownloadsRowLabel(
                    title: leaf.title,
                    uploader: leaf.uploader,
                    thumbnailURL: leaf.thumbnailURL,
                    accessibilityID: "downloads.queue.activeRow.\(position)"
                )
                Spacer(minLength: 0)
                DownloadsRowButton(
                    systemImage: "xmark.circle",
                    label: MacAMPStrings.downloadsQueueCancel,
                    accessibilityID: "downloads.queue.activeRow.\(position).cancelButton",
                    action: onCancel
                )
            }
            DownloadsProgressBar(leaf: leaf, position: position, isPaused: isPaused)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }
}

/// The poster frame, title and uploader shared by active and pending rows.
///
/// The row's accessibility identifier lives on the TITLE text rather than the enclosing
/// stack: an identifier on a container that is not itself an accessibility element is
/// shadowed by its children, so XCUITest would never resolve it (the
/// `assistant.chat.webPointer` lesson). The thumbnail carries no identifier at all — it
/// is `.accessibilityHidden(true)` decoration.
struct DownloadsRowLabel: View {
    let title: String
    let uploader: String?
    let thumbnailURL: URL?
    let accessibilityID: String

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            DownloadsRowThumbnail(url: thumbnailURL)
            VStack(alignment: .leading, spacing: tokens.spacing.hairline * 2) {
                Text(verbatim: title)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(1)
                    .accessibilityIdentifier(accessibilityID)
                if let uploader {
                    Text(verbatim: uploader)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A borderless inline row control for the download queue (cancel on an active row) and
/// the history list (reveal in Finder).
/// Mirrors `KaraokeQueueRowButton`: `.plain`, tertiary by default and accent on hover,
/// with a `Rectangle` hit shape so a click fires the action without selecting the row.
///
/// ``isEnabled`` and ``help`` exist for the history list's Reveal control, which must
/// stay VISIBLE while the file it points at is gone — a control that disappeared would
/// leave the row silently missing an action, whereas an inert one with a reason attached
/// says what happened. A disabled instance drops to the disabled text role, stops
/// reacting to hover and takes NO pointing-hand cursor: the cursor signals
/// interactivity, and a greyed inert control must not claim it (SKILL, macOS UI
/// interaction standards).
struct DownloadsRowButton: View {
    let systemImage: String
    /// Names the ACTION, for VoiceOver. Unchanged by the enabled state — the reason a
    /// control is inert belongs in ``help``, not in the name of what it does.
    let label: LocalizedStringResource
    /// Tooltip override; ``label`` is used when absent.
    var help: LocalizedStringResource?
    var isEnabled = true
    let accessibilityID: String
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = isEnabled && $0 }
        .help(Text(help ?? label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(accessibilityID)

        if isEnabled {
            button.pointingHandCursor()
        } else {
            button
        }
    }

    private var tint: Color {
        guard isEnabled else { return tokens.colors.textDisabled.resolve(scheme) }
        return isHovered
            ? tokens.colors.accent.resolve(scheme)
            : tokens.colors.textTertiary.resolve(scheme)
    }
}

/// One row's bar and caption — and the only place that row's live state is read.
///
/// An indeterminate phase (metadata prefetch, post-processing) has no fraction to draw,
/// so the bar falls back to the linear indeterminate style rather than pretending to be
/// at zero.
struct DownloadsProgressBar: View {
    let leaf: DownloadRowLeaf
    let position: Int
    let isPaused: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.downloadsRowBodyProbe) private var bodyProbe

    var body: some View {
        // The one body a sample is SUPPOSED to move, and the one whose count separates
        // this implementation from a store-wide state map (see DownloadsRowBodyProbe).
        _ = bodyProbe?(.progress, leaf.id)
        return VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            bar
            Text(DownloadStateCaption.currentText(
                for: leaf.state,
                format: leaf.resolvedFormat,
                isPaused: isPaused
            ))
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = leaf.fraction {
            ProgressView(value: fraction)
                .tint(tokens.colors.accent.resolve(scheme))
                .accessibilityIdentifier(identifier)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(tokens.colors.accent.resolve(scheme))
                .accessibilityIdentifier(identifier)
        }
    }

    /// Numbered per row, because N transfers mean N bars and an unnumbered identifier
    /// would resolve to whichever one XCUITest happened to find first.
    private var identifier: String {
        "downloads.queue.activeRow.\(position).progress"
    }
}
