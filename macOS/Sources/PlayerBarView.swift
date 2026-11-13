// PlayerBarView — the bespoke transport bar pinned to the bottom of the window.
//
// A three-zone desktop-player layout: a now-playing identity on the leading edge
// (artwork + title/artist, tap to open the full `PlayerView`), a centered
// transport cluster — shuffle / previous / play-pause / next / repeat — stacked
// over the seek scrubber, and a volume control on the trailing edge. The bar
// recolors around the current artwork: the art-derived accent flows into every
// `TransportButton`, the `PlayerSlider` fill and the repeat badge via themed
// `DesignTokens`, with a faint art wash over the surface. Under
// reduce-transparency the wash is dropped for a solid `canvas` fallback; theme /
// scrub / press animations all honor reduce-motion (the design-system components
// collapse them internally). Artwork is a fixed size while every label scales
// with Dynamic Type.
//
// The three zones are split into `PlayerBarIdentity`, `PlayerBarTransport` and
// `PlayerBarScrubber` sibling views so each observes only its own slice of the
// `PlayerViewModel`: the 0.5 s progress ticker (owned by the scrubber) re-renders
// just the scrubber, never the identity or transport. The album theme and design
// tokens are applied once here at the bar level so every subview inherits them.
//
// Transport, shuffle, repeat, volume and stereo balance all forward to the
// existing `PlayerViewModel` bindings (no coordinator/state-logic change).
import DesignSystem
import GRDB
import Persistence
import SwiftUI

struct PlayerBarView: View {
    @Binding var showRightPanel: Bool
    var onIdentityTap: (() -> Void)?
    var onProfileTap: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var albumTheme: AlbumTheme?
    @State private var trackRecord: TrackRecord?

    var body: some View {
        bar
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .background(barBackground)
            .overlay(alignment: .top) { topSeparator }
            .designTokens(tokens)
            .albumTheme(albumTheme)
            .themePresentation(presentation)
            .animation(themeAnimation, value: albumTheme)
            .task(id: themeKey) { albumTheme = await loadTheme() }
            .task(id: environment.player.currentTrack?.trackID) { loadTrackRecord() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.bar")
    }

    private var tokens: DesignTokens {
        settings.designTokens
    }

    private var presentation: ThemePresentationOptions {
        ThemePresentationOptions(
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased
        )
    }
}

// MARK: - Layout

private extension PlayerBarView {
    var bar: some View {
        HStack(spacing: tokens.spacing.medium) {
            if settings.profilesEnabled {
                ProfileAvatarButton(action: { onProfileTap?() })
            }
            PlayerBarIdentity(trackRecord: trackRecord, onIdentityTap: onIdentityTap)
                .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
            center
                .frame(maxWidth: 500)
                .layoutPriority(1)
            if settings.showVisualizer {
                InlineSpectrumHost(minimumInterval: 1.0 / 30.0)
            }
            PlayerVolumeControl()
                .frame(minWidth: 100, maxWidth: 200, alignment: .trailing)
        }
        .padding(.horizontal, tokens.spacing.xLarge)
        .padding(.vertical, tokens.spacing.medium)
    }

    /// The transport cluster stacked over the seek scrubber, each a sibling view
    /// so only the scrubber re-renders on the 0.5 s progress tick.
    var center: some View {
        VStack(spacing: tokens.spacing.xxSmall) {
            PlayerBarTransport()
            PlayerBarScrubber(trackRecord: trackRecord)
        }
    }

    var barBackground: some View {
        ZStack {
            if reduceTransparency {
                tokens.colors.canvas.resolve(scheme).opacity(0.80)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(0.80))
                if let albumTheme {
                    albumTheme.background.shapeStyleView(for: scheme)
                        .opacity(0.14)
                }
            }
        }
    }

    /// A token hairline that crisply separates the chrome from the content above.
    var topSeparator: some View {
        Rectangle()
            .fill(tokens.colors.separator.resolve(scheme))
            .frame(height: tokens.spacing.hairline)
    }
}

// MARK: - Theme + track record

private extension PlayerBarView {
    var themeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: tokens.motion.expressive)
    }

    var artworkHash: String? {
        environment.player.artwork?.contentHash
    }

    var themeKey: AlbumThemeKey {
        AlbumThemeKey(contentHash: artworkHash, options: presentation)
    }

    func loadTrackRecord() {
        guard let trackID = environment.player.currentTrack?.trackID else {
            trackRecord = nil
            return
        }
        trackRecord = try? environment.database.writer.read { db in
            try TrackRecord.fetchOne(db, key: trackID)
        }
    }

    func loadTheme() async -> AlbumTheme? {
        await AlbumArtTheming.theme(forArtwork: environment.player.artwork?.data, options: presentation)
    }
}

#Preview("Player bar · Light") {
    @Previewable @State var panel = false
    PlayerBarView(showRightPanel: $panel)
        .environment(AppEnvironment.preview())
        .environment(PlayIntent())
        .frame(width: 880)
        .preferredColorScheme(.light)
}

#Preview("Player bar · Dark") {
    @Previewable @State var panel = false
    PlayerBarView(showRightPanel: $panel)
        .environment(AppEnvironment.preview())
        .environment(PlayIntent())
        .frame(width: 880)
        .preferredColorScheme(.dark)
}
