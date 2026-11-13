// PlayerView — the full now-playing surface, bound to `PlayerViewModel`.
//
// A segmented control hosts three panes: Now Playing (large artwork, transport,
// seek scrubber, volume, ReplayGain mode), the Equalizer (`EQPanelView`) and the
// Lyrics panel (`LyricsPanelView`). The whole surface recolors around the current
// artwork — an accent + an art-derived gradient backdrop (`ThemedBackground`) —
// extracted off-main and applied as themed `DesignTokens`. Transport/shuffle/
// repeat forward to `PlayerViewModel`; ReplayGain mode lives on `EQViewModel`.
//
// Volume has no view-model/engine binding yet (the VM + `PlaybackEngine` expose
// none — SFB volume is macOS-only and unsurfaced), so the fader tracks local
// state, mirroring the design-system gallery, pending a future wiring task.
import CoreGraphics
import DesignSystem
import Services
import SwiftUI

/// The three panes of the full player.
enum PlayerPane: String, CaseIterable, Identifiable {
    case nowPlaying, equalizer, lyrics

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .nowPlaying: MacAMPStrings.playerNowPlaying
        case .equalizer: MacAMPStrings.playerEqualizer
        case .lyrics: MacAMPStrings.playerLyrics
        }
    }
}

/// The full now-playing view, presented over the main window.
struct PlayerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var pane: PlayerPane = .nowPlaying
    @State private var scrubFraction: Double?
    @State private var isHoveringScrubber = false
    @State private var isScrubbing = false
    @State private var hasHeat = false
    @State private var volume = 0.7
    @State private var artworkImage: CGImage?
    @State private var albumTheme: AlbumTheme?

    var body: some View {
        ZStack {
            ThemedBackground()
            chrome
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 640, idealHeight: 780)
        .designTokens(tokens)
        .albumTheme(albumTheme)
        .themePresentation(presentation)
        .animation(themeAnimation, value: albumTheme)
        .task(id: themeKey) { albumTheme = await loadTheme() }
        .task(id: artworkHash) { decodeArtwork() }
        .onActiveTick(isActive: environment.player.isPlaying, every: 0.5) { tickProgress() }
    }

    private var tokens: DesignTokens {
        albumTheme?.applied(to: .standard) ?? .standard
    }

    private var presentation: ThemePresentationOptions {
        ThemePresentationOptions(
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased
        )
    }
}

// MARK: - Chrome

private extension PlayerView {
    var chrome: some View {
        VStack(spacing: tokens.spacing.large) {
            topBar
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(tokens.spacing.xLarge)
    }

    var topBar: some View {
        HStack(spacing: tokens.spacing.medium) {
            Picker(selection: $pane) {
                ForEach(PlayerPane.allCases) { pane in
                    Text(pane.label).tag(pane)
                }
            } label: {
                Text(MacAMPStrings.playerNowPlaying)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer(minLength: tokens.spacing.small)

            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(MacAMPStrings.playerClose))
        }
    }

    @ViewBuilder
    var paneContent: some View {
        switch pane {
        case .nowPlaying: nowPlayingPane
        case .equalizer: EQPanelView()
        case .lyrics: LyricsPanelView()
        }
    }
}

// MARK: - Now playing

private extension PlayerView {
    var nowPlayingPane: some View {
        VStack(spacing: tokens.spacing.large) {
            ArtworkView(image: artworkImage, shadow: tokens.elevation.high)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)
            trackMeta
            scrubberBlock
            transportRow
            secondaryRow
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var trackMeta: some View {
        if let track = environment.player.currentTrack {
            VStack(spacing: tokens.spacing.xxSmall) {
                Text(verbatim: track.title ?? track.filePath)
                    .font(tokens.typography.displayMedium.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(1)
                if let artist = track.artist, !artist.isEmpty {
                    Text(verbatim: artist)
                        .font(tokens.typography.titleMedium.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
        } else {
            Text(MacAMPStrings.notPlaying)
                .font(tokens.typography.displayMedium.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
    }

    var scrubberBlock: some View {
        VStack(spacing: tokens.spacing.xSmall) {
            ScrubberHeatCaption(isVisible: isHeatCaptionVisible)
                .frame(maxWidth: .infinity, alignment: .leading)
            PlayerSlider(
                value: seekBinding,
                label: DesignSystemStrings.seekLabel,
                onEditingChanged: scrubChanged
            )
            .background {
                ScrubberHeatOverlay(isRevealed: isHeatRevealed) { hasHeat = $0 }
            }
            .onHover { isHoveringScrubber = $0 }
            HStack {
                Text(verbatim: PlaybackTime.clock(displayElapsed))
                Spacer()
                Text(verbatim: "-" + PlaybackTime.clock(remaining))
            }
            .font(tokens.typography.timecode.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

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
            KaraokeButton()
        }
        .frame(maxWidth: .infinity)
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
                    .padding(tokens.spacing.xxSmall)
            }
        }
    }

    var secondaryRow: some View {
        HStack(spacing: tokens.spacing.large) {
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                PlayerSlider(value: $volume, label: DesignSystemStrings.volumeLabel)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            Picker(selection: replayGainBinding) {
                ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                    Text(MacAMPStrings.playerReplayGainName(mode)).tag(mode)
                }
            } label: {
                Text(MacAMPStrings.playerReplayGain)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityLabel(Text(MacAMPStrings.playerReplayGain))
        }
    }
}

// MARK: - Bindings + actions

private extension PlayerView {
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

    var isHeatRevealed: Bool {
        isHoveringScrubber || isScrubbing
    }

    var isHeatCaptionVisible: Bool {
        ScrubberHeatLabel.isVisible(isRevealed: isHeatRevealed, hasHeat: hasHeat)
    }

    func scrubChanged(_ editing: Bool) {
        isScrubbing = editing
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
        artworkImage = AlbumArtImage.decode(environment.player.artwork?.data, maxPixel: 640)
    }

    func loadTheme() async -> AlbumTheme? {
        await AlbumArtTheming.theme(forArtwork: environment.player.artwork?.data, options: presentation)
    }
}

#Preview("Player · Light") {
    PlayerView()
        .environment(AppEnvironment.preview())
        .preferredColorScheme(.light)
}

#Preview("Player · Dark") {
    PlayerView()
        .environment(AppEnvironment.preview())
        .preferredColorScheme(.dark)
}
