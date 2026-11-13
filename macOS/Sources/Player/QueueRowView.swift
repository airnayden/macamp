// QueueRowView — one manual-queue entry, built on the shared ``TrackListRow``.
// Extracted from the former `QueuePanelView` so the full-width ``QueueView``
// reuses it verbatim instead of re-declaring the row.
import DesignSystem
import Services
import SwiftUI

/// A single queue entry built on the shared ``TrackListRow``. It owns its own hover
/// state so the row paints a subtle `surfaceRaised` highlight under the pointer —
/// plain `List` rows have no native hover affordance on macOS.
struct QueueRowView: View {
    let entry: TrackRef
    let number: Int
    let isCurrent: Bool
    let karaokeState: TrackRowKaraokeState?
    let karaokeEnabled: Bool
    let onRequestKaraokeRender: (() -> Void)?
    let onDequeueKaraoke: (() -> Void)?
    let onPlay: () -> Void
    let onRemove: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        TrackListRow(
            number: number,
            title: entry.title ?? entry.url.lastPathComponent,
            artist: entry.artist,
            duration: entry.duration,
            isPlaying: isCurrent,
            availability: entry.availability,
            karaokeState: karaokeState,
            onRequestKaraokeRender: onRequestKaraokeRender,
            onDequeueKaraoke: onDequeueKaraoke
        )
        .padding(.horizontal, tokens.spacing.xSmall)
        .background(rowHighlight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu {
            KaraokeRenderMenuButton(filePaths: [entry.filePath], enabled: karaokeEnabled)
            Button(MacAMPStrings.queueRemove, action: onRemove)
        }
    }

    private var rowHighlight: some View {
        RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
            .fill(isHovered ? tokens.colors.surfaceRaised.resolve(scheme) : .clear)
    }
}
