// PlayerBarIdentity — the leading-edge now-playing identity of the player bar.
//
// Artwork thumbnail + title / artist (tap to open the full `PlayerView`).
// Extracted from `PlayerBarView` so the 0.5 s playback ticker no longer
// invalidates this zone: the identity only re-renders on a track / artwork
// change, never on elapsed progress. Owns its own decoded-artwork `@State`; the
// album theme and design tokens flow in from the parent bar's environment.
import CoreGraphics
import DesignSystem
import Persistence
import SwiftUI

struct PlayerBarIdentity: View {
    var trackRecord: TrackRecord?
    var onIdentityTap: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var artworkImage: CGImage?

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            if let artworkImage {
                Image(decorative: artworkImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous))
            }
            identityText
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onIdentityTap?() }
        .pointingHandCursor()
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onIdentityTap?() }
        .accessibilityIdentifier("player.identity")
        .task(id: artworkHash) { decodeArtwork() }
    }

    @ViewBuilder
    private var identityText: some View {
        if let track = environment.player.currentTrack {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                MarqueeText(
                    text: track.title ?? track.filePath,
                    font: tokens.typography.headline.font,
                    color: tokens.colors.textPrimary.resolve(scheme),
                    isActive: environment.player.isPlaying
                )
                if let artist = track.artist, !artist.isEmpty {
                    ArtistLink(name: artist, artistId: trackRecord?.artistId)
                        .font(tokens.typography.caption.font)
                        .lineLimit(1)
                }
            }
        } else {
            Text(MacAMPStrings.notPlaying)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .lineLimit(1)
        }
    }

    private var artworkHash: String? {
        environment.player.artwork?.contentHash
    }

    private func decodeArtwork() {
        artworkImage = AlbumArtImage.decode(environment.player.artwork?.data, maxPixel: 112)
    }
}
