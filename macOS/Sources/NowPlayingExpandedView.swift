import CoreGraphics
import DesignSystem
import Persistence
import Services
import SwiftUI
import Visualizer

struct NowPlayingExpandedView: View {
    @Binding var isPresented: Bool

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var artworkImage: CGImage?
    @State private var isClosing = false
    @State private var isAppearing = true
    @FocusState private var hasKeyFocus: Bool

    var body: some View {
        VStack(spacing: tokens.spacing.large) {
            closeBar
            Spacer()
            artwork
            trackInfo
            visualizer
            OverlayScrubber(paused: isAppearing || isClosing)
            transport
            volumeRow
            Spacer()
        }
        .padding(.horizontal, tokens.spacing.xLarge)
        .padding(.vertical, tokens.spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The exit command reaches only the FOCUSED view, and the first responder is
        // whatever field was last touched behind the overlay — so taking key focus
        // is what makes Esc arrive. `focusEffectDisabled` is not optional: a focused
        // window-sized view otherwise draws AppKit's animated blurred focus ring.
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyFocus)
        .onExitCommand(perform: dismiss)
        .onAppear { hasKeyFocus = true }
        // No own background: the presenting overlay in `MainWindowView` fades a
        // static full-window backdrop behind this view while the content slides —
        // a full-window backdrop attached HERE re-rasterized its backing store on
        // every frame of the `.move` transition.
        .task(id: environment.player.artwork?.contentHash) { await decodeArtwork() }
        .task {
            try? await Task.sleep(for: .seconds(0.35))
            isAppearing = false
        }
    }

    private var closeBar: some View {
        HStack {
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "Close"))
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
            if let artworkImage {
                Image(decorative: artworkImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
        }
        .frame(width: 280, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    @ViewBuilder
    private var trackInfo: some View {
        if let track = environment.player.currentTrack {
            VStack(spacing: tokens.spacing.xSmall) {
                MarqueeText(
                    text: track.title ?? track.filePath,
                    font: tokens.typography.titleLarge.font,
                    color: tokens.colors.textPrimary.resolve(scheme),
                    isActive: environment.player.isPlaying
                )
                if let artist = track.artist, !artist.isEmpty {
                    MarqueeText(
                        text: artist,
                        font: tokens.typography.body.font,
                        color: tokens.colors.textSecondary.resolve(scheme),
                        isActive: environment.player.isPlaying
                    )
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var transport: some View {
        HStack(spacing: tokens.spacing.large) {
            TransportButton(.previous, size: .medium, action: environment.player.previous)
            TransportButton(
                environment.player.isPlaying ? .pause : .play,
                prominence: .prominent,
                size: .large,
                action: environment.player.togglePlayPause
            )
            TransportButton(.next, size: .medium, action: environment.player.next)
        }
    }

    private var visualizer: some View {
        Group {
            if settings.showVisualizer {
                InlineSpectrumHost(forcePaused: isClosing || isAppearing, minimumInterval: 1.0 / 30.0)
                    .frame(width: 200, height: 48)
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: tokens.spacing.small) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            PlayerSlider(value: volumeBinding, label: DesignSystemStrings.volumeLabel)
                .designTokens(settings.designTokens)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .font(tokens.typography.caption.font)
        .frame(maxWidth: 280)
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(environment.player.volume) },
            set: { environment.player.setVolume(Float($0)) }
        )
    }

    private func dismiss() {
        isClosing = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { isPresented = false }
        }
    }

    private func decodeArtwork() async {
        artworkImage = await AlbumArtImage.decodeOffMain(environment.player.artwork?.data, maxPixel: 280)
    }
}

/// The seek slider + timecodes, split out so only THIS view observes `elapsed`:
/// with the scrubber inline, every 0.5 s progress tick re-rendered the entire
/// overlay (artwork, transport, volume), hitching it while music played. It also
/// owns the progress ticker, paused during the overlay's enter/exit transition.
///
/// The replay-heat state lives HERE for the same reason the scrubber does: hover
/// and the loaded curve must not invalidate the artwork and transport around it.
/// `paused` gates only the progress ticker — the reveal is hover-driven and stays
/// live through the enter/exit transition, and the curve is static data anyway.
private struct OverlayScrubber: View {
    var paused: Bool

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var scrubFraction: Double?
    @State private var isHoveringScrubber = false
    @State private var isScrubbing = false
    @State private var hasHeat = false

    var body: some View {
        VStack(spacing: tokens.spacing.xxSmall) {
            ScrubberHeatCaption(isVisible: isHeatCaptionVisible)
                .frame(maxWidth: 320, alignment: .leading)
            PlayerSlider(
                value: seekBinding,
                label: DesignSystemStrings.seekLabel,
                onEditingChanged: scrubChanged
            )
            .designTokens(settings.designTokens)
            .background {
                ScrubberHeatOverlay(isRevealed: isHeatRevealed) { hasHeat = $0 }
            }
            .onHover { isHoveringScrubber = $0 }
            .frame(maxWidth: 320)
            HStack {
                Text(verbatim: PlaybackTime.clock(displayElapsed))
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                Spacer()
                Text(verbatim: "-" + PlaybackTime.clock(remaining))
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .frame(maxWidth: 320)
        }
        .onActiveTick(isActive: environment.player.isPlaying && !paused, every: 0.5) {
            guard scrubFraction == nil else { return }
            environment.player.refreshProgress()
        }
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { scrubFraction ?? progressFraction },
            set: { scrubFraction = $0 }
        )
    }

    private var progressFraction: Double {
        let duration = environment.player.duration
        guard duration > 0 else { return 0 }
        return min(1, max(0, environment.player.elapsed / duration))
    }

    private var displayElapsed: Double {
        if let scrubFraction { return scrubFraction * environment.player.duration }
        return environment.player.elapsed
    }

    private var remaining: Double {
        max(0, environment.player.duration - displayElapsed)
    }

    private var isHeatRevealed: Bool {
        isHoveringScrubber || isScrubbing
    }

    private var isHeatCaptionVisible: Bool {
        ScrubberHeatLabel.isVisible(isRevealed: isHeatRevealed, hasHeat: hasHeat)
    }

    private func scrubChanged(_ editing: Bool) {
        isScrubbing = editing
        guard !editing, let fraction = scrubFraction else { return }
        environment.player.seek(to: fraction * environment.player.duration)
        scrubFraction = nil
    }
}
