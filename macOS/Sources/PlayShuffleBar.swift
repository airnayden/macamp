import DesignSystem
import Persistence
import Services
import SwiftUI

struct PlayShuffleBar: View {
    let tracks: [TrackRecord]
    let source: PlaybackSource
    @Binding var filterText: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    init(
        tracks: [TrackRecord],
        source: PlaybackSource,
        filterText: Binding<String> = .constant("")
    ) {
        self.tracks = tracks
        self.source = source
        _filterText = filterText
    }

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            actionButton(icon: "play.fill", label: MacAMPStrings.playlistPlayAll) {
                playAll(shuffled: false)
            }
            actionButton(icon: "shuffle", label: MacAMPStrings.playlistShuffle) {
                playAll(shuffled: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .font(tokens.typography.caption.font)
                TextField(String(localized: MacAMPStrings.filterTracks), text: $filterText)
                    .accessibilityLabel(Text(MacAMPStrings.filterTracks))
                    .accessibilityIdentifier("library.filterTracks")
                    .textFieldStyle(.plain)
                    .font(tokens.typography.callout.font)
                    .frame(maxWidth: 180)
                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(Text(MacAMPStrings.helpClearSearch))
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(
                Capsule(style: .continuous)
                    .fill(tokens.colors.surfaceRaised.resolve(scheme))
            )
        }
        .padding(.horizontal, tokens.spacing.medium)
        .padding(.vertical, tokens.spacing.xSmall)
    }

    private func actionButton(
        icon: String,
        label: LocalizedStringResource,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: icon)
                Text(label)
            }
            .font(tokens.typography.callout.font)
            .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(Capsule(style: .continuous).fill(tokens.colors.accent.resolve(scheme)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func playAll(shuffled: Bool) {
        let refs = tracks.map { TrackRef(record: $0) }
        guard !refs.isEmpty else { return }
        if shuffled {
            environment.coordinator.setQueue(refs.shuffled(), startingAt: 0, source: source)
            environment.player.setShuffle(true)
        } else {
            environment.coordinator.setQueue(refs, startingAt: 0, source: source)
            environment.player.setShuffle(false)
        }
        environment.queue.refresh()
    }
}
