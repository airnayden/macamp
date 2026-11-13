// KaraokeButtonStrings — localized copy for the player-bar karaoke (vocal-removal)
// toggle (Task 16). Follows the shell's `extension MacAMPStrings` convention (see
// `TooltipStrings.swift`) so the button never carries a bare user-facing literal and
// stays localization-clean (`scripts/check-hardcoded-strings.sh`).
//
// The DISABLED state's help/hint text deliberately comes from
// `SeparationUnavailableReason.message` (owned by the `Separation` module, already a
// `LocalizedStringResource`) — those reasons are NOT duplicated here.
import Foundation

extension MacAMPStrings {
    /// VoiceOver label for the karaoke toggle in the transport bar.
    static let karaokeAccessibilityLabel = LocalizedStringResource(
        "player.karaoke.accessibilityLabel",
        defaultValue: "Karaoke Mode",
        comment: "Accessibility label for the player-bar karaoke (vocal-removal) toggle"
    )
    /// VoiceOver hint for the karaoke toggle when it is pressable (ready / active).
    static let karaokeAccessibilityHint = LocalizedStringResource(
        "player.karaoke.accessibilityHint",
        defaultValue: "Removes the vocals from the current track",
        comment: "Accessibility hint describing what the karaoke toggle does"
    )
    /// VoiceOver hint while the current track's instrumental is still rendering.
    static let karaokePreparingAccessibilityHint = LocalizedStringResource(
        "player.karaoke.preparingAccessibilityHint",
        defaultValue: "Preparing the instrumental",
        comment: "Accessibility hint shown while the karaoke instrumental is being prepared"
    )
    /// Hover tooltip for the karaoke toggle (all non-disabled states).
    static let karaokeHelp = LocalizedStringResource(
        "player.karaoke.help",
        defaultValue: "Toggle karaoke mode",
        comment: "Hover tooltip for the player-bar karaoke toggle"
    )
    /// Hover tooltip for the karaoke toggle when a press RENDERS the instrumental on
    /// demand (``KaraokeButtonState/renderable`` — no cached version yet).
    static let karaokeRenderableHelp = LocalizedStringResource(
        "player.karaoke.renderable.help",
        defaultValue: "Create karaoke version",
        comment: "Hover tooltip for the player-bar karaoke toggle when pressing it renders the instrumental on demand"
    )
    /// VoiceOver hint for the karaoke toggle in its renderable state (press renders).
    static let karaokeRenderableAccessibilityHint = LocalizedStringResource(
        "player.karaoke.renderable.accessibilityHint",
        defaultValue: "Creates a karaoke version of the current track",
        comment: "Accessibility hint for the karaoke toggle when pressing it renders the instrumental on demand"
    )
    /// VoiceOver value announced on the karaoke toggle when a cached instrumental is
    /// ready (the accent-dot indicator distinguishing ready from renderable).
    static let karaokeReadyIndicatorAccessibilityLabel = LocalizedStringResource(
        "player.karaoke.ready.indicatorAccessibilityLabel",
        defaultValue: "Karaoke version ready",
        comment: "Accessibility value announced when the current track already has a cached karaoke instrumental"
    )
    /// Toast shown when karaoke auto-turns-off because the current song has no
    /// cached instrumental (activation-miss or an advance onto an uncached track).
    static let karaokeAutoDeactivatedToast = LocalizedStringResource(
        "player.karaoke.autoDeactivated.toast",
        defaultValue: "Karaoke turned off — no karaoke version for this song",
        comment: "Toast shown when karaoke automatically disables because the current track has no rendered instrumental"
    )
    /// Rejection when the chosen karaoke cache folder is equal to or inside a music folder.
    static let karaokeCacheInsideRoot = LocalizedStringResource(
        "player.karaoke.cacheDirectory.rejected.insideRoot",
        defaultValue: "That folder is inside a music folder. Choose a location outside your music folders.",
        comment: "Rejection when the chosen karaoke cache directory is equal to or inside a library-root music folder"
    )
    /// Rejection when the chosen karaoke cache folder contains a music folder.
    static let karaokeCacheContainsRoot = LocalizedStringResource(
        "player.karaoke.cacheDirectory.rejected.containsRoot",
        defaultValue: "That folder contains a music folder. Choose a location that doesn’t hold your music folders.",
        comment: "Rejection when the chosen karaoke cache directory contains a library-root music folder"
    )
}
