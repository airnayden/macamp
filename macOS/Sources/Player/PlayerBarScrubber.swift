// PlayerBarScrubber — the seek scrubber + timecodes of the player bar.
//
// The format capsule (`SignalPathButton`, which opens the signal-path panel),
// elapsed / remaining timecodes and the `PlayerSlider`, plus the 0.5 s playback
// ticker that refreshes progress. This is the ONLY zone that observes
// `environment.player.elapsed`, so the twice-a-second tick invalidates just this
// subview instead of the whole bar. `trackRecord` supplies the bitrate /
// sample-rate / bit-depth fallback; the album accent flows into the slider from
// the parent bar's `\.albumTheme` environment.
import DesignSystem
import Persistence
import SwiftUI

struct PlayerBarScrubber: View {
    var trackRecord: TrackRecord?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var scrubFraction: Double?
    @State private var isHoveringScrubber = false
    @State private var isScrubbing = false
    @State private var hasHeat = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 280
            HStack(spacing: tokens.spacing.small) {
                if !compact {
                    SignalPathButton(trackRecord: trackRecord)
                }
                Text(verbatim: PlaybackTime.clock(displayElapsed))
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .fixedSize()
                PlayerSlider(
                    value: seekBinding,
                    label: DesignSystemStrings.seekLabel,
                    onEditingChanged: scrubChanged
                )
                .designTokens(tokens)
                .background {
                    ScrubberHeatOverlay(isRevealed: isHeatRevealed) { hasHeat = $0 }
                }
                .onHover { isHoveringScrubber = $0 }
                .scrubberHeatTooltip(hasHeat: hasHeat)
                Text(verbatim: "-" + PlaybackTime.clock(remaining))
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .fixedSize()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 18)
        .onActiveTick(isActive: environment.player.isPlaying, every: 0.5) { tickProgress() }
    }

    private var seekBinding: Binding<Double> {
        Binding(get: { scrubFraction ?? progressFraction }, set: { scrubFraction = $0 })
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

    /// This 18 pt row has no vertical room for the visible caption the full player
    /// and the expanded overlay use, so the bar names the curve with a tooltip
    /// instead — see ``SwiftUI/View/scrubberHeatTooltip(hasHeat:)``.
    private var isHeatRevealed: Bool {
        isHoveringScrubber || isScrubbing
    }

    private func scrubChanged(_ editing: Bool) {
        isScrubbing = editing
        guard !editing, let fraction = scrubFraction else { return }
        environment.player.seek(to: fraction * environment.player.duration)
        scrubFraction = nil
    }

    private func tickProgress() {
        // `isPlaying` gating lives in `onActiveTick` (incl. one flush tick on
        // pause); keep only the drag guard so a live scrub isn't overwritten.
        guard scrubFraction == nil else { return }
        environment.player.refreshProgress()
    }
}
