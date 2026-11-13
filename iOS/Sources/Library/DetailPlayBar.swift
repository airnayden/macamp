// DetailPlayBar — the Play / Shuffle capsule pair shared by the album and artist
// detail headers (Task 33). Mirrors the playlist-detail header buttons so every
// detail destination plays a collection from the top or shuffled with one tap.
import DesignSystem
import SwiftUI

struct DetailPlayBar: View {
    let playTitle: LocalizedStringResource
    let shuffleTitle: LocalizedStringResource
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.medium) {
            button(playTitle, systemImage: "play.fill", action: onPlay)
            button(shuffleTitle, systemImage: "shuffle", action: onShuffle)
        }
        .padding(.top, tokens.spacing.xSmall)
    }

    private func button(
        _ title: LocalizedStringResource,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, tokens.spacing.small)
            .background(Capsule(style: .continuous).fill(tokens.colors.accent.resolve(scheme)))
        }
        .buttonStyle(.plain)
    }
}
