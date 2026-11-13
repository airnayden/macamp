// MenuBarView — the macOS menu-bar mini player.
//
// The content of the `MenuBarExtra` scene (presented with
// `.menuBarExtraStyle(.window)` in `MacAMPApp`): a compact now-playing card
// (art thumbnail + title/artist), a seek scrubber with elapsed/remaining
// read-outs, a centered previous / play-pause / next transport, a quick volume
// fader, and a footer that brings the main window forward or quits. Everything
// binds to the shared `PlayerViewModel` from `AppEnvironment`, so playback state
// stays live without duplicating any transport logic.
//
// This surface shows STATIC now-playing only — never a live spectrum. It never
// touches `VisualizerViewModel`, so opening the popover does not resume the
// audio tap / GPU; the visualizer stays power-gated to its own host view.
//
// The scrubber carries the replay-heat curve (`ScrubberHeatOverlay`), revealed on
// hover or drag like every other MacAMP scrubber. It names the curve with the
// TOOLTIP form (`scrubberHeatTooltip`) rather than the visible `ScrubberHeatCaption`
// the full player and expanded overlay use — not because a row would not fit, but
// because this popover carries no text labels at all today (card → slider →
// buttons → slider → footer). The only prose above the scrubber would read as a
// heading for the popover rather than a name for a decoration, and the caption is
// permanently in the layout by design, so a ~24 pt row would grow a ~320 pt
// summon-and-dismiss utility for text visible only while hovering.
//
// `.menuBarExtraStyle(.window)` rebuilds this content on each open, so the
// overlay's `.task(id:)` re-runs and re-reads exactly one `playSegmentHeat` row
// per presentation. That is the intended coarse refresh, not a leak: the row can
// only change when a listen flushes, so there is nothing to poll and nothing to
// keep alive between openings.
//
import AppKit
import CoreGraphics
import DesignSystem
import SwiftUI

/// The menu-bar mini player shown inside the `MenuBarExtra` window popover.
struct MenuBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    @State private var scrubFraction: Double?
    @State private var isHoveringScrubber = false
    @State private var isScrubbing = false
    @State private var hasHeat = false
    @State private var artworkImage: CGImage?
    @State private var hostingWindow: NSWindow?

    private let tokens = DesignTokens.standard

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            nowPlaying
            scrubber
            transport
            volumeControl
            Divider()
            footer
        }
        .padding(tokens.spacing.large)
        .frame(width: 300)
        .background(tokens.colors.surface.resolve(scheme))
        .background(MenuBarWindowAccessor { hostingWindow = $0 })
        .designTokens(tokens)
        .task(id: artworkHash) { decodeArtwork() }
        .onActiveTick(isActive: environment.player.isPlaying, every: 0.5) { tickProgress() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(MenuBarStrings.miniPlayer))
    }
}

// MARK: - Now playing

private extension MenuBarView {
    var nowPlaying: some View {
        HStack(spacing: tokens.spacing.small) {
            ArtworkView(
                image: artworkImage,
                cornerRadius: tokens.radii.small,
                shadow: tokens.elevation.low
            )
            .frame(width: 56, height: 56)
            infoText
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var infoText: some View {
        if let track = environment.player.currentTrack {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                MarqueeText(
                    text: track.title ?? track.filePath,
                    font: tokens.typography.headline.font,
                    color: tokens.colors.textPrimary.resolve(scheme),
                    isActive: environment.player.isPlaying
                )
                if let artist = track.artist, !artist.isEmpty {
                    MarqueeText(
                        text: artist,
                        font: tokens.typography.caption.font,
                        color: tokens.colors.textSecondary.resolve(scheme),
                        isActive: environment.player.isPlaying
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(MacAMPStrings.notPlaying)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
    }
}

// MARK: - Scrubber + transport + volume

private extension MenuBarView {
    var scrubber: some View {
        VStack(spacing: tokens.spacing.xSmall) {
            PlayerSlider(
                value: seekBinding,
                label: DesignSystemStrings.seekLabel,
                onEditingChanged: scrubChanged
            )
            .background {
                ScrubberHeatOverlay(isRevealed: isHeatRevealed) { hasHeat = $0 }
            }
            .onHover { isHoveringScrubber = $0 }
            .scrubberHeatTooltip(hasHeat: hasHeat)
            HStack {
                Text(verbatim: PlaybackTime.clock(displayElapsed))
                Spacer()
                Text(verbatim: "-" + PlaybackTime.clock(remaining))
            }
            .font(tokens.typography.timecode.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

    var transport: some View {
        HStack(spacing: tokens.spacing.large) {
            TransportButton(.previous, size: .small, action: environment.player.previous)
            TransportButton(
                environment.player.isPlaying ? .pause : .play,
                prominence: .prominent,
                size: .medium,
                action: environment.player.togglePlayPause
            )
            TransportButton(.next, size: .small, action: environment.player.next)
        }
        .frame(maxWidth: .infinity)
    }

    var volumeControl: some View {
        HStack(spacing: tokens.spacing.small) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            PlayerSlider(value: volumeBinding, label: DesignSystemStrings.volumeLabel)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .font(tokens.typography.caption.font)
    }
}

// MARK: - Footer

private extension MenuBarView {
    var footer: some View {
        HStack(spacing: tokens.spacing.medium) {
            Button(action: showMainWindow) {
                Label {
                    Text(MenuBarStrings.show) + Text(verbatim: " MacAMP")
                } icon: {
                    Image(systemName: "macwindow")
                }
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: quit) {
                Label {
                    Text(MenuBarStrings.quit)
                } icon: {
                    Image(systemName: "power")
                }
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Bindings + actions

private extension MenuBarView {
    var seekBinding: Binding<Double> {
        Binding(get: { scrubFraction ?? progressFraction }, set: { scrubFraction = $0 })
    }

    var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(environment.player.volume) },
            set: { environment.player.setVolume(Float($0)) }
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

    var isHeatRevealed: Bool {
        isHoveringScrubber || isScrubbing
    }

    var artworkHash: String? {
        environment.player.artwork?.contentHash
    }

    func scrubChanged(_ editing: Bool) {
        isScrubbing = editing
        guard !editing, let fraction = scrubFraction else { return }
        environment.player.seek(to: fraction * environment.player.duration)
        scrubFraction = nil
    }

    func tickProgress() {
        // `isPlaying` gating lives in `onActiveTick` (incl. one flush tick on
        // pause); keep only the drag guard so a live scrub isn't overwritten.
        guard scrubFraction == nil else { return }
        environment.player.refreshProgress()
    }

    func decodeArtwork() {
        artworkImage = AlbumArtImage.decode(environment.player.artwork?.data, maxPixel: 112)
    }

    func showMainWindow() {
        hostingWindow?.close()
        NSApp.activate()
        openWindow(id: "main")
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Popover dismissal

/// Captures the popover's hosting `NSWindow` so ``MenuBarView/showMainWindow()``
/// can dismiss the panel before activating the app.
///
/// `MenuBarExtra` publishes no presented-state binding on any shipping SDK. Its
/// one `Binding<Bool>` initializer controls whether the STATUS ITEM EXISTS, so
/// binding it would delete the menu-bar icon rather than close the popover.
/// Closing the hosting window is the supported dismissal — never that binding.
private struct MenuBarWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    /// Resolves on the next run-loop turn — the same live-window seam
    /// ``SettingsWindowResizable`` uses. Reading `window` synchronously from
    /// `viewDidMoveToWindow` reports it back inside SwiftUI's own update pass.
    final class Helper: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onResolve?(window)
            }
        }
    }

    func makeNSView(context _: Context) -> Helper {
        let view = Helper()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: Helper, context _: Context) {
        nsView.onResolve = onResolve
    }
}

#Preview {
    MenuBarView()
        .environment(AppEnvironment.preview())
}
