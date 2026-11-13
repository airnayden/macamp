import CoreGraphics
import DesignSystem
import SwiftUI

struct RightPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var artworkImage: CGImage?

    /// Not `@State`: the tab lives on ``NavigationModel`` so other surfaces can
    /// open the panel already switched to a chosen tab.
    private var tabBinding: Binding<RightPanelTab> {
        Binding(get: { nav.rightPanelTab }, set: { nav.rightPanelTab = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 340)
        .background(tokens.colors.surface.resolve(scheme).opacity(0.25))
        .task(id: environment.player.artwork?.contentHash) {
            artworkImage = await AlbumArtImage.decodeOffMain(environment.player.artwork?.data, maxPixel: 240)
        }
    }

    private var header: some View {
        VStack(spacing: tokens.spacing.small) {
            artworkSection
            trackIdentity
            tabPicker
        }
        .padding(.horizontal, tokens.spacing.medium)
        .padding(.top, tokens.spacing.medium)
        .padding(.bottom, tokens.spacing.small)
    }

    private var artworkSection: some View {
        ArtworkView(
            image: artworkImage,
            cornerRadius: tokens.radii.large,
            shadow: tokens.elevation.medium
        )
        .frame(width: 120, height: 120)
        .frame(maxWidth: .infinity)
        .compositingGroup()
    }

    @ViewBuilder
    private var trackIdentity: some View {
        if let track = environment.player.currentTrack {
            VStack(spacing: tokens.spacing.xxSmall) {
                MarqueeText(
                    text: track.title ?? track.url.lastPathComponent,
                    font: tokens.typography.titleMedium.font,
                    color: tokens.colors.textPrimary.resolve(scheme),
                    isActive: environment.player.isPlaying
                )
                .multilineTextAlignment(.center)
                if let artist = track.artist, !artist.isEmpty {
                    ArtistLink(name: artist, artistId: nil)
                        .font(tokens.typography.caption.font)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var tabPicker: some View {
        Picker(selection: tabBinding) {
            ForEach(RightPanelTab.allCases) { item in
                Text(item.label)
                    .tag(item)
                    .accessibilityIdentifier("rightPanel.tab.\(item.rawValue)")
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("rightPanel.tabPicker")
    }

    private var tabContent: some View {
        Group {
            switch nav.rightPanelTab {
            case .lyrics: LyricsPanelView()
            case .tags: TagsPanelView()
            case .info: InfoPanelView()
            case .stats: StatsPanelView()
            }
        }
        .padding(.horizontal, tokens.spacing.small)
    }
}

#Preview {
    RightPanelView()
        .environment(AppEnvironment.preview())
        .environment(NavigationModel())
        .designTokens(.standard)
        .frame(width: 340, height: 600)
}
