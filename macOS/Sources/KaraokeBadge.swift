// KaraokeBadge — the karaoke "instrumental ready" / "rendering" accessory shown in
// every macOS track list, plus the shared gating + render-request helpers its
// parent views use to feed it.
//
// The badge itself is a plain leaf: it takes an already-resolved
// ``TrackRowKaraokeState`` and draws a small accent `music.mic` glyph (a cached
// instrumental is ready to play), a mini progress ring (a render is in flight), or a
// clock (the track is waiting in the render queue). The queued clock is the one
// interactive state — the PARENT hands it a dequeue action for pending items so a
// click drops the track from the queue. The PARENT owns the O(1) store lookups and
// hands ``TrackListRow`` plain values — the row never touches the environment, so a
// 100k-row list stays cheap to scroll (a hard performance invariant).
//
// The gating lives here once (``AppEnvironment/karaokeRowState(filePath:enabled:)``):
// nothing is shown unless karaoke is enabled AND a separation model is bundled
// (`karaokeRender != nil`), so App Store / CI / fresh-clone builds show no badge and
// offer no render action.
import DesignSystem
import Foundation
import Services
import SwiftUI
import ViewModels

/// What a track row shows in its karaoke accessory slot. An absent value (`nil` at
/// the call site) means nothing is drawn.
enum TrackRowKaraokeState: Equatable {
    /// A cached instrumental exists — engaging karaoke plays instantly.
    case ready
    /// A render is in flight; the associated value is its `0...1` progress. Shown for
    /// the in-flight (current) queue item only — a non-interactive ring.
    case rendering(Double)
    /// The track is waiting in the render queue (a PENDING item, not yet in flight).
    /// Interactive: its clock icon is a button that removes it from the queue.
    case queued
}

/// The karaoke accessory badge for a track row: a ready glyph, an in-flight ring, or
/// a queued clock. The queued clock is interactive when `onDequeue` is supplied (the
/// PARENT provides it only for pending queue items) — it becomes a button that drops
/// the track from the render queue; ready and rendering stay non-interactive.
struct KaraokeBadge: View {
    let state: TrackRowKaraokeState
    var onDequeue: (() -> Void)?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch state {
        case .ready:
            Image(systemName: "music.mic")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .help(Text(KaraokeBadgeStrings.ready))
                .accessibilityLabel(Text(KaraokeBadgeStrings.ready))
        case let .rendering(progress):
            KaraokeRowProgressRing(progress: progress)
        case .queued:
            if let onDequeue {
                KaraokeDequeueButton(action: onDequeue)
            } else {
                Image(systemName: "clock")
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .help(Text(KaraokeBadgeStrings.queued))
                    .accessibilityLabel(Text(KaraokeBadgeStrings.queued))
            }
        }
    }
}

/// A 14×14 accent progress ring for an in-flight instrumental render. Value-driven
/// (`Circle().trim`) so it honors reduce-motion by construction.
private struct KaraokeRowProgressRing: View {
    let progress: Double

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle()
                .stroke(tokens.colors.accentMuted.resolve(scheme), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    tokens.colors.accent.resolve(scheme),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .help(Text(KaraokeBadgeStrings.rendering))
        .accessibilityLabel(Text(KaraokeBadgeStrings.rendering))
    }
}

/// A borderless inline "create karaoke version" button for a renderable track row.
///
/// It lets the user schedule an on-demand render straight from the list — no context
/// menu, no playing the track first. Tertiary by default, accent on hover: the same
/// restrained idiom as ``FavouriteButton`` in the same row. `.plain` style + a
/// `Rectangle` hit shape so a click fires the render without selecting the row or
/// triggering its double-click play. The PARENT decides whether it appears (it hands
/// ``TrackListRow`` the action only for renderable tracks), so this view is a pure
/// leaf — it never reads the environment.
struct KaraokeRenderButton: View {
    /// Schedules the on-demand instrumental render for this row's track.
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.badge.plus")
                .font(tokens.typography.caption.font)
                .foregroundStyle(
                    isHovered
                        ? tokens.colors.accent.resolve(scheme)
                        : tokens.colors.textTertiary.resolve(scheme)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text(KaraokeBadgeStrings.createVersion))
        .accessibilityLabel(Text(KaraokeBadgeStrings.createVersion))
        .accessibilityIdentifier("trackRow.karaokeRender")
        .pointingHandCursor()
    }
}

/// A borderless inline "remove from karaoke queue" button for a pending track row.
///
/// A queued (pending) track shows a clock the user can click to drop it from the
/// render queue. It mirrors ``KaraokeRenderButton`` exactly — tertiary by default,
/// accent on hover, `.plain` style + a `Rectangle` hit shape so a click dequeues
/// without selecting the row or triggering its double-click play. The PARENT hands it
/// down only for pending items (the in-flight render shows a non-interactive ring and
/// cannot be dequeued), so this view is a pure leaf that never reads the environment.
struct KaraokeDequeueButton: View {
    /// Removes this row's track from the karaoke render queue.
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock")
                .font(tokens.typography.caption.font)
                .foregroundStyle(
                    isHovered
                        ? tokens.colors.accent.resolve(scheme)
                        : tokens.colors.textTertiary.resolve(scheme)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text(KaraokeBadgeStrings.queued))
        .accessibilityLabel(Text(KaraokeBadgeStrings.queued))
        .accessibilityIdentifier("trackRow.karaokeDequeue")
        .pointingHandCursor()
    }
}

/// The "Create Karaoke Version" context-menu item, shared by every track-list
/// surface. It self-hides unless at least one of `filePaths` is renderable (karaoke
/// enabled, a model bundled, and the track neither ready nor already rendering), so a
/// ready row never offers to render again.
struct KaraokeRenderMenuButton: View {
    let filePaths: [String]
    let enabled: Bool

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let renderable = filePaths.filter {
            environment.canRequestKaraokeRender(filePath: $0, enabled: enabled)
        }
        if !renderable.isEmpty {
            Button {
                for path in renderable {
                    environment.requestKaraokeRender(filePath: path)
                }
            } label: {
                Label {
                    Text(KaraokeBadgeStrings.createVersion)
                } icon: {
                    Image(systemName: "music.mic")
                }
            }
        }
    }
}

// MARK: - Row gating + render request (computed by the PARENT, not the row)

extension AppEnvironment {
    /// The karaoke accessory state for a row, or `nil` when nothing should show.
    ///
    /// O(1) — a `Set` / dictionary lookup, safe to call for every visible row. When
    /// karaoke is off or no model is bundled it returns `nil` immediately, touching no
    /// observable state, so a disabled build costs nothing at 100k-row scale. The
    /// PARENT view calls this and passes the result to ``TrackListRow`` as a plain
    /// value; the row itself never reads the environment.
    func karaokeRowState(filePath: String, enabled: Bool) -> TrackRowKaraokeState? {
        guard enabled, karaokeRender != nil else { return nil }
        if let progress = karaokeReadyStore.progress(filePath: filePath) {
            return .rendering(progress)
        }
        if karaokeQueueStore.isQueued(filePath: filePath) { return .queued }
        if karaokeReadyStore.isReady(filePath: filePath) { return .ready }
        return nil
    }

    /// Whether a "Create Karaoke Version" action should be offered for `filePath`:
    /// karaoke enabled, a model bundled, and the track not already rendering, queued,
    /// or ready — the exact complement of ``karaokeRowState(filePath:enabled:)`` so a
    /// row shows either an accessory state or the render action, never both.
    func canRequestKaraokeRender(filePath: String, enabled: Bool) -> Bool {
        guard enabled, karaokeRender != nil else { return false }
        if karaokeReadyStore.progress(filePath: filePath) != nil { return false }
        if karaokeQueueStore.isQueued(filePath: filePath) { return false }
        return !karaokeReadyStore.isReady(filePath: filePath)
    }

    /// Enqueues an on-demand instrumental render for `filePath` (a no-op when no render
    /// service is available). The path is canonicalized downstream by the cache key.
    func requestKaraokeRender(filePath: String) {
        karaokeRender?.requestRender(URL(fileURLWithPath: filePath))
    }

    /// A render-request closure for a row, or `nil` when the track can't be rendered
    /// (karaoke off, no model bundled, or already ready / rendering) — the exact gate
    /// ``canRequestKaraokeRender(filePath:enabled:)`` uses. The PARENT computes this and
    /// hands ``TrackListRow`` a plain closure, so the row's inline render button appears
    /// only for renderable tracks and the row itself never touches the environment.
    func karaokeRenderAction(filePath: String, enabled: Bool) -> (() -> Void)? {
        guard canRequestKaraokeRender(filePath: filePath, enabled: enabled) else { return nil }
        return { self.requestKaraokeRender(filePath: filePath) }
    }

    /// A dequeue closure for a row, or `nil` when the track is not a removable pending
    /// queue item. Non-nil exactly when ``karaokeRowState(filePath:enabled:)`` returns
    /// ``TrackRowKaraokeState/queued`` (waiting in the queue but NOT the in-flight
    /// item — the current render shows a non-interactive ring and `removePending`
    /// no-ops on it). Reusing `karaokeRowState` keeps the gate DRY and guaranteed
    /// consistent with the displayed state. The PARENT computes this and hands
    /// ``TrackListRow`` a plain closure, so the row's queued clock removes the track
    /// from the queue and the row never touches the environment.
    func karaokeDequeueAction(filePath: String, enabled: Bool) -> (() -> Void)? {
        guard karaokeRowState(filePath: filePath, enabled: enabled) == .queued else { return nil }
        return { self.karaokeRender?.removePending(URL(fileURLWithPath: filePath)) }
    }
}

// MARK: - Localized copy (shell-local)

/// Localized copy for the karaoke row badge + render action.
enum KaraokeBadgeStrings {
    static let ready = LocalizedStringResource(
        "app.karaoke.badge.ready",
        defaultValue: "Karaoke version ready",
        comment: "Accessibility label / tooltip for the badge marking a track whose karaoke (vocal-removed) instrumental is cached and ready to play"
    )
    static let rendering = LocalizedStringResource(
        "app.karaoke.badge.rendering",
        defaultValue: "Creating karaoke version",
        comment: "Accessibility label / tooltip for the progress ring shown while a track's karaoke instrumental is being rendered"
    )
    static let createVersion = LocalizedStringResource(
        "app.karaoke.menu.createVersion",
        defaultValue: "Create Karaoke Version",
        comment: "Context-menu command that starts rendering a karaoke (vocal-removed) instrumental for the track"
    )
    static let queued = LocalizedStringResource(
        "app.karaoke.badge.queued",
        defaultValue: "Queued for karaoke — click to remove",
        comment: "Accessibility label / tooltip for the clock badge marking a track waiting in the karaoke render queue; clicking it removes the track from the queue"
    )
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        KaraokeBadge(state: .ready)
        KaraokeBadge(state: .rendering(0.35))
        KaraokeBadge(state: .rendering(0.8))
        KaraokeBadge(state: .queued, onDequeue: {})
        KaraokeBadge(state: .queued)
    }
    .padding()
    .designTokens(.standard)
}
