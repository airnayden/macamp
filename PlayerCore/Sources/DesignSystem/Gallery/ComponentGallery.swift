import SwiftUI

/// A living gallery of every design-system component, themed by sample album art
/// run through the real ``ThemeExtractor``. Also the canvas for the light/dark +
/// Dynamic Type previews that document the layer.
public struct ComponentGallery: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePresentation) private var presentation

    @State private var seek = 0.38
    @State private var volume = 0.66
    @State private var isPlaying = true
    @State private var albumTheme: AlbumTheme?

    public init() {}

    private var tokens: DesignTokens {
        albumTheme?.applied(to: .standard) ?? .standard
    }

    private let totalDuration = Duration.seconds(245)

    public var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: tokens.spacing.xLarge) {
                    header
                    nowPlayingCard
                    section(SampleArtwork.transportTitle) { transportRow }
                    section(SampleArtwork.volumeTitle) {
                        PlayerSlider(value: $volume, label: DesignSystemStrings.volumeLabel)
                    }
                    section(SampleArtwork.libraryTitle) { trackList }
                    section(SampleArtwork.statesTitle) { states }
                    section(SampleArtwork.paletteTitle) { paletteSection }
                    section(SampleArtwork.typeTitle) { typeSection }
                    section(SampleArtwork.elevationTitle) { elevationSection }
                    section(SampleArtwork.materialsTitle) { materialsSection }
                }
                .padding(tokens.spacing.xLarge)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .designTokens(tokens)
        .albumTheme(albumTheme)
        .task(id: presentation) { await loadTheme() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(verbatim: "MacAMP")
                .font(tokens.typography.displayLarge.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Text(verbatim: SampleArtwork.galleryTagline)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
    }

    private var nowPlayingCard: some View {
        VStack(spacing: tokens.spacing.large) {
            ArtworkView(image: SampleArtwork.heroImage)
                .frame(maxWidth: 260)

            VStack(spacing: tokens.spacing.xxSmall) {
                Text(verbatim: SampleArtwork.heroTitle)
                    .font(tokens.typography.displayMedium.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Text(verbatim: SampleArtwork.heroArtist)
                    .font(tokens.typography.titleMedium.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }

            VStack(spacing: tokens.spacing.xSmall) {
                PlayerSlider(value: $seek, buffered: 0.6, label: DesignSystemStrings.seekLabel)
                HStack {
                    Text(verbatim: elapsed)
                    Spacer()
                    Text(verbatim: remaining)
                }
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }

            transportRow
        }
        .padding(tokens.spacing.xLarge)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.xLarge, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme).opacity(0.86))
        )
        .shadow(for: tokens.elevation.high)
    }

    private var transportRow: some View {
        HStack(spacing: tokens.spacing.large) {
            TransportButton(.shuffle, size: .small, isActive: true) {}
            TransportButton(.previous) {}
            TransportButton(
                isPlaying ? .pause : .play,
                prominence: .prominent,
                size: .large
            ) { isPlaying.toggle() }
            TransportButton(.next) {}
            TransportButton(.repeatMode, size: .small) {}
        }
        .frame(maxWidth: .infinity)
    }

    private var trackList: some View {
        VStack(spacing: tokens.spacing.xSmall) {
            ForEach(SampleArtwork.tracks) { track in
                TrackRow(
                    title: track.title,
                    subtitle: track.artist,
                    artwork: track.artwork,
                    duration: track.duration,
                    isPlaying: track.isPlaying
                )
            }
        }
    }

    private var states: some View {
        VStack(spacing: tokens.spacing.large) {
            StateView.empty()
            StateView.loading()
            StateView.offline(
                action: StateView.Action(
                    title: DesignSystemStrings.transportPlay,
                    systemImage: "arrow.clockwise"
                ) {}
            )
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            Text(verbatim: title)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var elapsed: String {
        Duration.seconds(seek * totalDuration.seconds)
            .formatted(.time(pattern: .minuteSecond))
    }

    private var remaining: String {
        let left = max(0, totalDuration.seconds * (1 - seek))
        return "-" + Duration.seconds(left).formatted(.time(pattern: .minuteSecond))
    }

    private func loadTheme() async {
        guard
            let image = SampleArtwork.heroImage,
            let data = SampleArtwork.pngData(image)
        else { return }
        let extractor = ThemeExtractor()
        albumTheme = await extractor.theme(from: data, options: presentation)
    }
}

private extension ComponentGallery {
    var paletteSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: tokens.spacing.small)],
            spacing: tokens.spacing.small
        ) {
            swatch(tokens.colors.canvas, "Canvas")
            swatch(tokens.colors.surface, "Surface")
            swatch(tokens.colors.surfaceRaised, "Raised")
            swatch(tokens.colors.accent, "Accent")
            swatch(tokens.colors.accentMuted, "Accent muted")
            swatch(tokens.colors.success, "Success")
            swatch(tokens.colors.warning, "Warning")
            swatch(tokens.colors.danger, "Danger")
        }
    }

    func swatch(_ color: AdaptiveColor, _ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
        return VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            shape
                .fill(color.resolve(scheme))
                .frame(height: 52)
                .overlay(shape.strokeBorder(
                    tokens.colors.separator.resolve(scheme),
                    lineWidth: tokens.spacing.hairline
                ))
            Text(verbatim: name)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

    var typeSection: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            typeRow("Display", tokens.typography.displayMedium, tokens.colors.textPrimary)
            typeRow("Title", tokens.typography.titleLarge, tokens.colors.textPrimary)
            typeRow("Headline", tokens.typography.headline, tokens.colors.textPrimary)
            typeRow("Primary body", tokens.typography.body, tokens.colors.textPrimary)
            typeRow("Secondary", tokens.typography.body, tokens.colors.textSecondary)
            typeRow("Tertiary", tokens.typography.body, tokens.colors.textTertiary)
            typeRow("Disabled", tokens.typography.body, tokens.colors.textDisabled)
        }
    }

    func typeRow(_ label: String, _ token: FontToken, _ color: AdaptiveColor) -> some View {
        Text(verbatim: label)
            .font(token.font)
            .foregroundStyle(color.resolve(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var elevationSection: some View {
        HStack(spacing: tokens.spacing.large) {
            elevationCard(tokens.elevation.low, "Low")
            elevationCard(tokens.elevation.medium, "Medium")
            elevationCard(tokens.elevation.high, "High")
        }
        .frame(maxWidth: .infinity)
    }

    func elevationCard(_ shadow: ShadowToken, _ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
        return VStack(spacing: tokens.spacing.xSmall) {
            shape
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
                .frame(height: 64)
                .overlay(shape.strokeBorder(
                    tokens.colors.separator.resolve(scheme),
                    lineWidth: tokens.spacing.hairline
                ))
                .shadow(for: shadow)
            Text(verbatim: name)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    var materialsSection: some View {
        let materials = MaterialTokens.standard
        return ZStack {
            RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        tokens.colors.accent.resolve(scheme),
                        tokens.colors.danger.resolve(scheme),
                        tokens.colors.warning.resolve(scheme),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
            HStack(spacing: tokens.spacing.medium) {
                glassPanel(materials.chrome, "Chrome")
                glassPanel(materials.popover, "Popover")
                glassPanel(materials.hud, "HUD")
            }
            .padding(tokens.spacing.medium)
        }
        .frame(height: 124)
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous))
    }

    func glassPanel(_ level: MaterialLevel, _ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
        return Text(verbatim: name)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if presentation.reduceTransparency {
                    shape.fill(tokens.colors.surfaceRaised.resolve(scheme))
                } else {
                    shape.fill(level.material)
                }
            }
            .overlay(shape.strokeBorder(tokens.colors.separator.resolve(scheme), lineWidth: tokens.spacing.hairline))
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

#Preview("Gallery · Light") {
    ComponentGallery()
        .preferredColorScheme(.light)
}

#Preview("Gallery · Dark") {
    ComponentGallery()
        .preferredColorScheme(.dark)
}

#Preview("Gallery · XL Dynamic Type") {
    ComponentGallery()
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}

#Preview("Gallery · Reduce Transparency + Motion") {
    ComponentGallery()
        .themePresentation(ThemePresentationOptions(reduceTransparency: true, reduceMotion: true))
        .preferredColorScheme(.dark)
}
