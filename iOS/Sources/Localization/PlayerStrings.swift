// PlayerStrings — localized copy for the iOS now-playing / EQ / lyrics /
// visualizer surface.
//
// Defined as an `extension MacAMPStrings` so every player string lives under the
// same `ios.*` namespace as the shell copy while staying in the `Localization/`
// folder. Views reference these constants — never a bare literal — so the surface
// is localization-clean and passes `scripts/check-hardcoded-strings.sh`. The
// "MacAMP" brand is NEVER localized. Mode + ReplayGain display names map an enum
// to a localized resource (the keys match the design-system/visualizer keys).
import Foundation
import Services
import Visualizer

extension MacAMPStrings {
    // MARK: Now playing

    static let notPlaying = LocalizedStringResource(
        "ios.player.notPlaying",
        defaultValue: "Not Playing",
        comment: "Shown on the now-playing screen when no track is loaded"
    )
    static let nowPlayingEmptyTitle = LocalizedStringResource(
        "ios.player.empty.title",
        defaultValue: "Nothing Playing",
        comment: "Title of the now-playing empty state"
    )
    static let nowPlayingEmptyMessage = LocalizedStringResource(
        "ios.player.empty.message",
        defaultValue: "Pick a song from your library to start listening.",
        comment: "Body of the now-playing empty state"
    )
    static let playerEqualizer = LocalizedStringResource(
        "ios.player.equalizer",
        defaultValue: "Equalizer",
        comment: "Accessibility label for the button that opens the equalizer sheet"
    )
    static let playerLyrics = LocalizedStringResource(
        "ios.player.lyrics",
        defaultValue: "Lyrics",
        comment: "Accessibility label for the button that opens the lyrics sheet"
    )
    static let playerVisualizer = LocalizedStringResource(
        "ios.player.visualizer",
        defaultValue: "Visualizer",
        comment: "Accessibility label for the button that opens the visualizer"
    )
    static let done = LocalizedStringResource(
        "ios.common.done",
        defaultValue: "Done",
        comment: "Button that dismisses a presented sheet"
    )

    // MARK: ReplayGain

    static let replayGain = LocalizedStringResource(
        "ios.player.replayGain",
        defaultValue: "ReplayGain",
        comment: "Label for the ReplayGain normalization-mode control"
    )

    /// The localized display name for a ReplayGain mode.
    static func replayGainName(_ mode: ReplayGainMode) -> LocalizedStringResource {
        switch mode {
        case .off:
            LocalizedStringResource(
                "ios.player.replayGain.off",
                defaultValue: "Off",
                comment: "ReplayGain mode: normalization disabled"
            )
        case .track:
            LocalizedStringResource(
                "ios.player.replayGain.track",
                defaultValue: "Track",
                comment: "ReplayGain mode: normalize each track to a consistent loudness"
            )
        case .album:
            LocalizedStringResource(
                "ios.player.replayGain.album",
                defaultValue: "Album",
                comment: "ReplayGain mode: normalize per album, preserving album dynamics"
            )
        }
    }

    // MARK: Equalizer

    static let eqTitle = LocalizedStringResource(
        "ios.eq.title",
        defaultValue: "Equalizer",
        comment: "Title of the equalizer sheet"
    )
    static let eqPreset = LocalizedStringResource(
        "ios.eq.preset",
        defaultValue: "Preset",
        comment: "Label for the EQ preset picker"
    )
    static let eqCustom = LocalizedStringResource(
        "ios.eq.custom",
        defaultValue: "Custom",
        comment: "EQ preset picker entry shown after a manual band edit"
    )
    static let eqPreamp = LocalizedStringResource(
        "ios.eq.preamp",
        defaultValue: "Preamp",
        comment: "Label for the EQ pre-amplification read-out"
    )
    static let eqReset = LocalizedStringResource(
        "ios.eq.reset",
        defaultValue: "Reset",
        comment: "Button that flattens every EQ band to 0 dB"
    )
    static let eqBandGain = LocalizedStringResource(
        "ios.eq.bandGain",
        defaultValue: "Band gain",
        comment: "Accessibility label prefix for one EQ band fader"
    )

    // MARK: Lyrics

    static let lyricsTitle = LocalizedStringResource(
        "ios.lyrics.title",
        defaultValue: "Lyrics",
        comment: "Title of the lyrics sheet"
    )
    static let lyricsEmptyTitle = LocalizedStringResource(
        "ios.lyrics.empty.title",
        defaultValue: "No Lyrics",
        comment: "Title shown when a track has no resolvable lyrics"
    )
    static let lyricsEmptyMessage = LocalizedStringResource(
        "ios.lyrics.empty.message",
        defaultValue: "Lyrics will appear here when they're available for this track.",
        comment: "Body shown when a track has no resolvable lyrics"
    )

    // MARK: Visualizer

    static let visualizerTitle = LocalizedStringResource(
        "ios.visualizer.title",
        defaultValue: "Visualizer",
        comment: "Title of the audio visualizer surface"
    )
    static let visualizerModeLabel = LocalizedStringResource(
        "ios.visualizer.mode.label",
        defaultValue: "Visual Mode",
        comment: "Accessibility label for the visualizer mode switcher"
    )

    /// Localized display name for a visual mode. Default values mirror the
    /// `Visualizer` module's `fallbackDisplayName`.
    static func visualizerModeName(_ mode: VisualizerMode) -> LocalizedStringResource {
        switch mode {
        case .bars:
            LocalizedStringResource(
                "visualizer.mode.bars",
                defaultValue: "Spectrum Bars",
                comment: "Frequency-domain spectrum bars visual mode"
            )
        case .oscilloscope:
            LocalizedStringResource(
                "visualizer.mode.oscilloscope",
                defaultValue: "Oscilloscope",
                comment: "Time-domain waveform visual mode"
            )
        case .particles:
            LocalizedStringResource(
                "visualizer.mode.particles",
                defaultValue: "Particles",
                comment: "Spectrum-reactive particle field visual mode"
            )
        case .aurora:
            LocalizedStringResource(
                "visualizer.mode.aurora",
                defaultValue: "Aurora",
                comment: "Flowing aurora art visual mode"
            )
        }
    }
}
