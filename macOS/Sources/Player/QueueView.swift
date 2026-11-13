// QueueView — the sidebar `.queue` detail: the manual play queue (the tracks the
// user explicitly enqueued), as a full-width screen.
//
// Replaces the former right-panel `QueuePanelView` tab with no loss of behavior:
// the same `environment.queue.manualEntries` source, the same empty state, the same
// Clear action, and the same ``QueueRowView`` (double-click to play, context-menu
// karaoke render / dequeue + Remove, drag reorder).
import DesignSystem
import Foundation
import Services
import SwiftUI
import ViewModels

struct QueueView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: environment.player.currentTrack?.id) {
                environment.queue.refresh()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.view")
    }
}

// MARK: - Content

private extension QueueView {
    var manualEntries: [TrackRef] {
        environment.queue.manualEntries
    }

    @ViewBuilder
    var content: some View {
        if manualEntries.isEmpty {
            StateView(
                systemImage: LibrarySection.queue.systemImage,
                title: MacAMPStrings.queueEmptyTitle,
                message: MacAMPStrings.queueEmptyMessage
            )
            .synthwaveEmptyBackground()
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                queueList
            }
        }
    }

    var header: some View {
        HStack(spacing: 0) {
            Spacer()
            Button(role: .destructive) {
                environment.queue.clearManual()
            } label: {
                Label { Text(MacAMPStrings.queueClear) } icon: { Image(systemName: "trash") }
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(MacAMPStrings.queueClear))
            .accessibilityLabel(Text(MacAMPStrings.queueClear))
            .accessibilityIdentifier("queue.clearButton")
            .pointingHandCursor()
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    var queueList: some View {
        List {
            ForEach(Array(manualEntries.enumerated()), id: \.element.id) { index, entry in
                QueueRowView(
                    entry: entry,
                    number: index + 1,
                    isCurrent: false,
                    karaokeState: environment.karaokeRowState(
                        filePath: entry.filePath,
                        enabled: settings.karaokeEnabled
                    ),
                    karaokeEnabled: settings.karaokeEnabled,
                    onRequestKaraokeRender: environment.karaokeRenderAction(
                        filePath: entry.filePath,
                        enabled: settings.karaokeEnabled
                    ),
                    onDequeueKaraoke: environment.karaokeDequeueAction(
                        filePath: entry.filePath,
                        enabled: settings.karaokeEnabled
                    ),
                    onPlay: { environment.queue.playManual(at: index) },
                    onRemove: { environment.queue.removeManual(at: index) }
                )
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                environment.queue.moveManual(from: from, to: destination)
            }
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .accessibilityIdentifier("queue.list")
    }
}

#Preview {
    QueueView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
