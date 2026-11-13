// NowPlayingScreen — the iOS now-playing surface, bound to `PlayerViewModel`.
//
// Large artwork, track metadata, a seek scrubber, the transport row (shuffle /
// previous / play-pause / next / repeat) and a ReplayGain mode picker. The whole
// surface recolors around the current artwork — an accent + an art-derived
// gradient backdrop (`ThemedBackground`) extracted off-main and applied as themed
// `DesignTokens`. Toolbar buttons present the Equalizer, Lyrics and Visualizer as
// sheets. Track text is DATA → `Text(verbatim:)`.
import CoreGraphics
import DesignSystem
import Services
import SwiftUI

/// The sheets the now-playing screen can present.
private enum PlayerSheet: String, Identifiable {
    case equalizer, lyrics, visualizer

    var id: String {
        rawValue
    }
}

/// The now-playing screen.
struct NowPlayingScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var scrubFraction: Double?
    @State private var artworkImage: CGImage?
    @State private var albumTheme: AlbumTheme?
    @State private var activeSheet: PlayerSheet?

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedBackground()
                content
            }
            .navigationTitle(Text(MacAMPStrings.tabNowPlaying))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarButtons }
            .designTokens(tokens)
            .albumTheme(albumTheme)
            .themePresentation(presentation)
            .animation(themeAnimation, value: albumTheme)
            .task(id: themeKey) { albumTheme = await loadTheme() }
            .task(id: artworkHash) { decodeArtwork() }
            .onActiveTick(isActive: environment.player.isPlaying, every: 0.5) { tickProgress() }
            .sheet(item: $activeSheet) { sheet in sheetContent(sheet) }
        }
    }
}

// MARK: - Content

private extension NowPlayingScreen {
    @ViewBuilder
    var content: some View {
        if environment.player.currentTrack == nil {
            StateView(
                systemImage: "play.circle",
                title: MacAMPStrings.nowPlayingEmptyTitle,
                message: MacAMPStrings.nowPlayingEmptyMessage
            )
        } else {
            nowPlaying
        }
    }

    var nowPlaying: some View {
        ScrollView {
            VStack(spacing: tokens.spacing.xLarge) {
                ArtworkView(image: artworkImage, shadow: tokens.elevation.high)
                    .frame(maxWidth: 360)
                    .padding(.top, tokens.spacing.large)
                trackMeta
                scrubberBlock
                transportRow
                replayGainRow
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, tokens.spacing.xLarge)
            .padding(.bottom, tokens.spacing.xxLarge)
        }
    }

    @ViewBuilder
    var trackMeta: some View {
        if let track = environment.player.currentTrack {
            VStack(spacing: tokens.spacing.xxSmall) {
                Text(verbatim: track.title ?? track.filePath)
                    .font(tokens.typography.displayMedium.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let artist = track.artist, !artist.isEmpty {
                    Text(verbatim: artist)
                        .font(tokens.typography.titleMedium.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .lineLimit(1)
                }
            }
        }
    }

    var scrubberBlock: some View {
        VStack(spacing: tokens.spacing.xSmall) {
            PlayerSlider(
                value: seekBinding,
                label: DesignSystemStrings.seekLabel,
                onEditingChanged: scrubChanged
            )
            HStack {
                Text(verbatim: PlaybackTime.clock(displayElapsed))
                Spacer()
                Text(verbatim: "-" + PlaybackTime.clock(remaining))
            }
            .font(tokens.typography.timecode.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }
}

// MARK: - Transport

private extension NowPlayingScreen {
    var transportRow: some View {
        HStack(spacing: tokens.spacing.large) {
            TransportButton(.shuffle, size: .small, isActive: environment.player.shuffle) {
                environment.player.setShuffle(!environment.player.shuffle)
            }
            TransportButton(.previous, action: environment.player.previous)
            TransportButton(
                environment.player.isPlaying ? .pause : .play,
                prominence: .prominent,
                size: .large,
                action: environment.player.togglePlayPause
            )
            TransportButton(.next, action: environment.player.next)
            repeatButton
        }
    }

    var repeatButton: some View {
        TransportButton(
            .repeatMode,
            size: .small,
            isActive: environment.player.repeatMode != .off,
            action: cycleRepeat
        )
        .overlay(alignment: .topTrailing) {
            if environment.player.repeatMode == .one {
                Text(verbatim: "1")
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
        }
    }

    var replayGainRow: some View {
        Picker(selection: replayGainBinding) {
            ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                Text(MacAMPStrings.replayGainName(mode)).tag(mode)
            }
        } label: {
            Text(MacAMPStrings.replayGain)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Text(MacAMPStrings.replayGain))
    }

    @ToolbarContentBuilder
    var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { activeSheet = .visualizer } label: {
                Image(systemName: "waveform.circle")
            }
            .accessibilityLabel(Text(MacAMPStrings.playerVisualizer))
            Button { activeSheet = .lyrics } label: {
                Image(systemName: "quote.bubble")
            }
            .accessibilityLabel(Text(MacAMPStrings.playerLyrics))
            Button { activeSheet = .equalizer } label: {
                Image(systemName: "slider.vertical.3")
            }
            .accessibilityLabel(Text(MacAMPStrings.playerEqualizer))
        }
    }

    @ViewBuilder
    func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .equalizer:
            EQSheet().environment(environment).designTokens(tokens)
        case .lyrics:
            LyricsView().environment(environment).designTokens(tokens)
        case .visualizer:
            VisualizerSheet().environment(environment).designTokens(tokens)
        }
    }
}

// MARK: - Derived state + actions

private extension NowPlayingScreen {
    var tokens: DesignTokens {
        albumTheme?.applied(to: .standard) ?? .standard
    }

    var presentation: ThemePresentationOptions {
        ThemePresentationOptions(
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased
        )
    }

    var seekBinding: Binding<Double> {
        Binding(get: { scrubFraction ?? progressFraction }, set: { scrubFraction = $0 })
    }

    var replayGainBinding: Binding<ReplayGainMode> {
        Binding(
            get: { environment.equalizer.replayGainMode },
            set: { environment.equalizer.setReplayGainMode($0) }
        )
    }

    var progressFraction: Double {
        let duration = environment.player.duration
        guard duration > 0 else { return 0 }
        return min(1, max(0, environment.player.elapsed / duration))
    }

    var displayElapsed: Double {
        if let scrubFraction { return scrubFraction * environment.player.duration }
        return environment.player.elapsed
    }

    var remaining: Double {
        max(0, environment.player.duration - displayElapsed)
    }

    var themeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: tokens.motion.expressive)
    }

    var artworkHash: String? {
        environment.player.artwork?.contentHash
    }

    var themeKey: AlbumThemeKey {
        AlbumThemeKey(contentHash: artworkHash, options: presentation)
    }

    func scrubChanged(_ editing: Bool) {
        guard !editing, let fraction = scrubFraction else { return }
        environment.player.seek(to: fraction * environment.player.duration)
        scrubFraction = nil
    }

    func cycleRepeat() {
        let next: RepeatMode = switch environment.player.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        environment.player.setRepeatMode(next)
    }

    func tickProgress() {
        // `isPlaying` gating lives in `onActiveTick` (incl. one flush tick on
        // pause); keep only the drag guard so a live scrub isn't overwritten.
        guard scrubFraction == nil else { return }
        environment.player.refreshProgress()
    }

    func decodeArtwork() {
        artworkImage = AlbumArtImage.decode(environment.player.artwork?.data, maxPixel: 720)
    }

    func loadTheme() async -> AlbumTheme? {
        await AlbumArtTheming.theme(forArtwork: environment.player.artwork?.data, options: presentation)
    }
}

#Preview("Now Playing") {
    NowPlayingScreen()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
