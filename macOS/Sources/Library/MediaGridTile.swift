import Artwork
import DesignSystem
import Persistence
import Services
import SwiftUI

struct MediaGridTile: View {
    let title: String
    let subtitle: String?
    let fallbackIcon: String
    var artworkLoader: (() async -> CGImage?)?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var artworkImage: CGImage?
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: tokens.spacing.xSmall) {
            RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let artworkImage {
                        Image(decorative: artworkImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: fallbackIcon)
                            .font(.system(size: 28))
                            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                        .strokeBorder(isHovered ? tokens.colors.accent.resolve(scheme) : .clear, lineWidth: 2)
                )
                .onHover { isHovered = $0 }

            Text(verbatim: title)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .pointingHandCursor()
        .task { artworkImage = await artworkLoader?() }
    }
}
