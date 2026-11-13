// ScrubberHeatOverlay — the shell's binding of `ReplayHeatCurve` to the live player.
//
// One reusable backing for every scrubber that carries the replay heatmap: the
// player bar's `PlayerBarScrubber`, the full player's `PlayerView`, the expanded
// now-playing overlay's `OverlayScrubber`, and the menu-bar mini's `MenuBarView`.
// iOS is now the ONLY exclusion, and it is a structural one rather than a policy:
// the reveal is driven by hover, and iOS has no hover to drive it with. Porting it
// there needs a new trigger, not this file.
//
// The exclusion list shrank twice, both times by owner decision, and the trail is
// kept because the header used to argue the opposite. It shipped as a two-surface
// feature (bar + full player); the expanded overlay was added when a full-size
// now-playing surface behaving differently from the bar it was expanded from read
// as a bug rather than a policy; the menu-bar mini followed for the same reason —
// it is a scrubber, and the curve is now what a MacAMP scrubber does.
//
// It is meant to be layered as a `.background { }` of the `PlayerSlider`, which is
// what makes "no heat row ⇒ no layout shift" structural rather than careful: a
// background is sized by its host and occupies no layout space of its own, so the
// scrubber measures identically whether the curve is present, absent, or hidden.
//
// The load is keyed on (active profile, current track) only. A heatmap row is
// written when a listen FLUSHES, so it cannot move mid-track — polling it during
// playback would spend reads observing a value that is by construction constant.
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

struct ScrubberHeatOverlay: View {
    /// Hover or an in-progress scrub — the only two states that reveal the curve.
    var isRevealed: Bool

    /// Reports whether a curve is actually being drawn, so the host can name it
    /// (a caption or a tooltip) without duplicating the load. Fires on appearance
    /// and on every change, so a host that starts `false` is corrected once the
    /// row lands. `nil` for hosts that don't caption the curve.
    var onHeatChanged: ((Bool) -> Void)?

    @Environment(AppEnvironment.self) private var environment

    @State private var model: ScrubberHeatViewModel?

    var body: some View {
        ReplayHeatCurve(intensities: model?.heat ?? [], isRevealed: isRevealed)
            .task(id: loadKey) { await load() }
            .onChange(of: hasHeat, initial: true) { _, newValue in onHeatChanged?(newValue) }
    }

    /// Whether the loaded row has a shape to draw — read through the shared rule so
    /// what the host captions and what the curve paints can never disagree.
    private var hasHeat: Bool {
        ScrubberHeatLabel.hasHeat(model?.heat)
    }

    private var loadKey: ScrubberHeatLoadKey {
        ScrubberHeatLoadKey(
            profileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID,
            trackId: environment.player.currentTrack?.trackID
        )
    }

    private func load() async {
        let key = loadKey
        if model == nil {
            model = ScrubberHeatViewModel(repository: PlaySegmentHeatRepository(environment.database))
        }
        await model?.load(profileId: key.profileId, trackId: key.trackId)
    }
}

/// Re-keys `.task` on a track OR profile change — the only two events that can
/// change which heatmap row applies.
struct ScrubberHeatLoadKey: Equatable {
    let profileId: Int64
    let trackId: Int64?
}

/// Whether the "Most Replayed" label naming the curve should be shown.
///
/// The label is a claim ABOUT the curve, so it is gated on the curve's OWN content
/// rule (`ReplayHeatGeometry.hasContent`) rather than on a second, parallel one:
/// captioning a scrubber the curve decided to leave blank would name a shape that
/// is not there. Reveal alone is never enough — hovering a track with no history
/// must caption nothing.
///
/// A caseless enum of pure statics, off the view, so the rule is assertable from a
/// nonisolated test (`SwiftUI.View` is `@MainActor`, and a static on a conforming
/// type inherits that isolation).
enum ScrubberHeatLabel {
    /// `true` when `intensities` describes a curve the overlay is actually drawing.
    static func hasHeat(_ intensities: [Float]?) -> Bool {
        guard let intensities else { return false }
        return ReplayHeatGeometry.hasContent(intensities)
    }

    /// `true` when the label should be shown: revealed AND backed by a real curve.
    static func isVisible(isRevealed: Bool, hasHeat: Bool) -> Bool {
        isRevealed && hasHeat
    }

    /// The same rule for a host that holds the intensities rather than the verdict.
    static func isVisible(isRevealed: Bool, intensities: [Float]?) -> Bool {
        isVisible(isRevealed: isRevealed, hasHeat: hasHeat(intensities))
    }
}

extension View {
    /// Names the replay curve with a tooltip — the label form for scrubbers too
    /// compact to spend a row on ``ScrubberHeatCaption``.
    ///
    /// The modifier is applied unconditionally and only its `Text` changes, to an
    /// empty one when there is no curve (which pops no tooltip). Branching instead
    /// would change the host subtree's identity whenever `hasHeat` flips,
    /// discarding `ScrubberHeatOverlay`'s `@State` model and re-reading the row it
    /// had only just loaded.
    func scrubberHeatTooltip(hasHeat: Bool) -> some View {
        help(hasHeat ? Text(MacAMPStrings.playerMostReplayed) : Text(verbatim: ""))
    }
}

/// The "Most Replayed" caption that names the curve `ScrubberHeatOverlay` draws.
///
/// Always present in the view tree and revealed by a plain opacity toggle — the
/// same discipline `ReplayHeatCurve` uses. Two things follow by construction: the
/// scrubber block measures identically whether the caption shows or not (no
/// hover-time layout jump), and there is no animation to suppress under
/// reduce-motion.
///
/// Deliberately hidden from accessibility: `ReplayHeatCurve` already carries
/// `DesignSystemStrings.replayHeatLabel` on the very shape this names, so exposing
/// the caption too would make VoiceOver announce one curve twice.
struct ScrubberHeatCaption: View {
    var isVisible: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(MacAMPStrings.playerMostReplayed)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .lineLimit(1)
            .fixedSize()
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
