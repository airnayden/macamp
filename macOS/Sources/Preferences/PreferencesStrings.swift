// PreferencesStrings — user-facing copy for the Settings window.
//
// Every label resolves through a `LocalizedStringResource` with an English
// `defaultValue`, so the running app and previews show real copy now and the
// dotted keys (`app.preferences.<area>.<element>`) are the single handoff list
// for Task 44. Copy deliberately avoids the "MacAMP" brand (the brand is never
// localized; it is rendered with `Text(verbatim: "MacAMP")` at call sites).
//
// Strings already owned elsewhere are reused at the call sites rather than
// duplicated here: ReplayGain copy from `MacAMPStrings.player*`, visual-mode
// names from `VisualizerStrings.modeName`, and the music-folders pane from
// `FileAccessStrings` (Task 29).
import Foundation

/// Localized copy for the Preferences window and its panes.
enum PreferencesStrings {
    // MARK: Tab titles

    static let tabGeneral = LocalizedStringResource(
        "app.preferences.tab.general",
        defaultValue: "General",
        comment: "Preferences tab: general appearance and startup options"
    )
    static let tabLibrary = LocalizedStringResource(
        "app.preferences.tab.library",
        defaultValue: "Library",
        comment: "Preferences tab: music folders and library options"
    )
    static let tabPlayback = LocalizedStringResource(
        "app.preferences.tab.playback",
        defaultValue: "Playback",
        comment: "Preferences tab: playback and normalization options"
    )
    static let tabEqualizer = LocalizedStringResource(
        "app.preferences.tab.equalizer",
        defaultValue: "Equalizer",
        comment: "Preferences tab: default equalizer preset"
    )
    static let tabVisualizer = LocalizedStringResource(
        "app.preferences.tab.visualizer",
        defaultValue: "Visualizer",
        comment: "Preferences tab: default visualizer mode"
    )
    static let tabOnline = LocalizedStringResource(
        "app.preferences.tab.online",
        defaultValue: "Online",
        comment: "Preferences tab: online data and lyrics fetching"
    )
    static let tabUpdates = LocalizedStringResource(
        "app.preferences.tab.updates",
        defaultValue: "Updates",
        comment: "Preferences tab: software-update channel"
    )
    static let tabAcknowledgments = LocalizedStringResource(
        "app.preferences.tab.acknowledgments",
        defaultValue: "Acknowledgments",
        comment: "Preferences tab: open-source acknowledgments"
    )

    // MARK: Pane hero-header subtitles

    static let generalSubtitle = LocalizedStringResource(
        "app.preferences.general.subtitle",
        defaultValue: "Appearance and startup behavior.",
        comment: "One-line subtitle under the General preferences pane title"
    )
    static let playbackSubtitle = LocalizedStringResource(
        "app.preferences.playback.subtitle",
        defaultValue: "Loudness normalization and gapless.",
        comment: "One-line subtitle under the Playback preferences pane title"
    )
    static let equalizerSubtitle = LocalizedStringResource(
        "app.preferences.equalizer.subtitle",
        defaultValue: "The equalizer preset applied at each launch.",
        comment: "One-line subtitle under the Equalizer preferences pane title"
    )
    static let visualizerSubtitle = LocalizedStringResource(
        "app.preferences.visualizer.subtitle",
        defaultValue: "How the visualizer looks when it first opens.",
        comment: "One-line subtitle under the Visualizer preferences pane title"
    )
    static let onlineSubtitle = LocalizedStringResource(
        "app.preferences.online.subtitle",
        defaultValue: "Control what MacAMP fetches from the internet.",
        comment: "One-line subtitle under the Online preferences pane title"
    )
    static let updatesSubtitle = LocalizedStringResource(
        "app.preferences.updates.subtitle",
        defaultValue: "How software updates are delivered.",
        comment: "One-line subtitle under the Updates preferences pane title"
    )
    static let librarySubtitle = LocalizedStringResource(
        "app.preferences.library.subtitle",
        defaultValue: "The folders MacAMP scans for music.",
        comment: "One-line subtitle under the Library preferences pane title"
    )

    // MARK: General pane

    static let appearance = LocalizedStringResource(
        "app.preferences.general.appearance",
        defaultValue: "Appearance",
        comment: "Label for the Light/Dark/System appearance picker"
    )
    static let appearanceSystem = LocalizedStringResource(
        "app.preferences.general.appearance.system",
        defaultValue: "System",
        comment: "Appearance option: follow the system Light/Dark setting"
    )
    static let appearanceLight = LocalizedStringResource(
        "app.preferences.general.appearance.light",
        defaultValue: "Light",
        comment: "Appearance option: always Light"
    )
    static let appearanceDark = LocalizedStringResource(
        "app.preferences.general.appearance.dark",
        defaultValue: "Dark",
        comment: "Appearance option: always Dark"
    )

    // MARK: Playback pane

    static let replayGain = LocalizedStringResource(
        "app.preferences.playback.replayGain",
        defaultValue: "Volume normalization",
        comment: "Label for the ReplayGain normalization-mode picker"
    )
    static let replayGainCaption = LocalizedStringResource(
        "app.preferences.playback.replayGain.caption",
        defaultValue: "Even out loudness differences between tracks or whole albums.",
        comment: "Explains the ReplayGain normalization-mode picker"
    )
    static let replayGainOff = LocalizedStringResource(
        "app.preferences.playback.replayGain.off",
        defaultValue: "Off",
        comment: "ReplayGain option: no loudness normalization"
    )
    static let replayGainTrack = LocalizedStringResource(
        "app.preferences.playback.replayGain.track",
        defaultValue: "Per track",
        comment: "ReplayGain option: normalize each track to a consistent loudness"
    )
    static let replayGainAlbum = LocalizedStringResource(
        "app.preferences.playback.replayGain.album",
        defaultValue: "Per album",
        comment: "ReplayGain option: normalize per album, preserving album dynamics"
    )
    static let gapless = LocalizedStringResource(
        "app.preferences.playback.gapless",
        defaultValue: "Gapless playback",
        comment: "Toggle that removes silence between consecutive tracks"
    )
    static let gaplessCaption = LocalizedStringResource(
        "app.preferences.playback.gapless.caption",
        defaultValue: "Play consecutive tracks with no silence between them.",
        comment: "Explains the gapless-playback toggle"
    )

    // MARK: Equalizer pane

    static let defaultPreset = LocalizedStringResource(
        "app.preferences.equalizer.defaultPreset",
        defaultValue: "Default preset",
        comment: "Label for the picker choosing the EQ preset applied at launch"
    )
    static let defaultPresetCaption = LocalizedStringResource(
        "app.preferences.equalizer.defaultPreset.caption",
        defaultValue: "This preset is applied each time the app launches.",
        comment: "Explains the default-EQ-preset picker"
    )

    // MARK: Visualizer pane

    static let defaultMode = LocalizedStringResource(
        "app.preferences.visualizer.defaultMode",
        defaultValue: "Default mode",
        comment: "Label for the picker choosing the visualizer's startup mode"
    )
    static let defaultModeCaption = LocalizedStringResource(
        "app.preferences.visualizer.defaultMode.caption",
        defaultValue: "Shown when the visualizer first opens.",
        comment: "Explains the default-visualizer-mode picker"
    )
    static let showVisualizer = LocalizedStringResource(
        "app.preferences.visualizer.show",
        defaultValue: "Show visualizer",
        comment: "Toggle that shows or hides the inline spectrum visualizer"
    )
    static let showVisualizerCaption = LocalizedStringResource(
        "app.preferences.visualizer.show.caption",
        defaultValue: "Show the spectrum visualizer in the player bar and the now-playing view.",
        comment: "Explains the show-visualizer toggle"
    )

    // MARK: Online pane

    static let onlineData = LocalizedStringResource(
        "app.preferences.online.data",
        defaultValue: "Online song, artist & album info",
        comment: "Toggle that enables fetching song, artist and album info from the internet"
    )
    static let onlineDataCaption = LocalizedStringResource(
        "app.preferences.online.data.caption",
        defaultValue: "Fetch descriptions, biographies and album details from the internet (MusicBrainz, Wikipedia).",
        comment: "Explains the online song/artist/album info toggle"
    )
    static let onlineLyrics = LocalizedStringResource(
        "app.preferences.online.lyrics",
        defaultValue: "Online lyrics",
        comment: "Toggle that enables fetching lyrics from the internet"
    )
    static let onlineLyricsCaption = LocalizedStringResource(
        "app.preferences.online.lyrics.caption",
        defaultValue: "Fetch lyrics from the internet (LRCLIB) when a track has none embedded.",
        comment: "Explains the online lyrics toggle"
    )
    static let onlineDataDisabledHint = LocalizedStringResource(
        "app.preferences.online.data.disabledHint",
        defaultValue: "Online info is turned off. Enable it in Settings ▸ Online to fetch song, artist and album details.",
        comment: "Shown in the Info panel when online info is disabled"
    )
    static let onlineLyricsDisabledHint = LocalizedStringResource(
        "app.preferences.online.lyrics.disabledHint",
        defaultValue: "Online lyrics are turned off. Enable them in Settings ▸ Online to fetch lyrics.",
        comment: "Shown in the Lyrics panel when online lyrics are disabled"
    )

    // MARK: Updates pane

    static let updateChannel = LocalizedStringResource(
        "app.preferences.updates.channel",
        defaultValue: "Update channel",
        comment: "Label for the software-update channel picker"
    )
    static let updateChannelStable = LocalizedStringResource(
        "app.preferences.updates.channel.stable",
        defaultValue: "Stable",
        comment: "Update channel option: shipping releases only"
    )
    static let updateChannelBeta = LocalizedStringResource(
        "app.preferences.updates.channel.beta",
        defaultValue: "Beta",
        comment: "Update channel option: pre-release builds"
    )
    static let updateChannelCaption = LocalizedStringResource(
        "app.preferences.updates.channel.caption",
        defaultValue: "Beta builds arrive earlier and may be less stable.",
        comment: "Caption under the software-update channel picker"
    )
    static let checkForUpdates = LocalizedStringResource(
        "app.preferences.updates.check",
        defaultValue: "Check for Updates…",
        comment: "Button that checks for software updates"
    )
    static let checkForUpdatesHelp = LocalizedStringResource(
        "app.preferences.updates.check.help",
        defaultValue: "Look for a new version of MacAMP now.",
        comment: "Tooltip on the button that checks for software updates"
    )
    static let updatesAutomatic = LocalizedStringResource(
        "app.preferences.updates.automatic",
        defaultValue: "MacAMP also checks for updates automatically in the background.",
        comment: "Caption explaining that update checks also happen on their own"
    )
}

// MARK: - Theme preset

extension PreferencesStrings {
    static let themePreset = LocalizedStringResource(
        "app.preferences.general.themePreset",
        defaultValue: "Accent Color",
        comment: "Label for the accent-color preset picker in General preferences"
    )
}

// MARK: - Interface language

extension PreferencesStrings {
    static let language = LocalizedStringResource(
        "app.preferences.general.language",
        defaultValue: "Language",
        comment: "Label for the picker choosing the language the interface is shown in"
    )
    static let languageSystem = LocalizedStringResource(
        "app.preferences.general.language.system",
        defaultValue: "System (Automatic)",
        comment: "Language option: follow the language chosen in macOS System Settings"
    )
    static let languageCaption = LocalizedStringResource(
        "app.preferences.general.language.caption",
        defaultValue: "The new language appears the next time MacAMP starts.",
        comment: "Caption stating that a language change only takes effect after a restart"
    )
    static let languageRelaunch = LocalizedStringResource(
        "app.preferences.general.language.relaunch",
        defaultValue: "Relaunch Now",
        comment: "Button that quits MacAMP and opens it again so the new language takes effect"
    )
    static let languageRelaunchHelp = LocalizedStringResource(
        "app.preferences.general.language.relaunch.help",
        defaultValue: "Quit MacAMP and open it again to switch language now.",
        comment: "Tooltip on the button that relaunches the app to apply the chosen language"
    )
    static let languageRelaunchFailed = LocalizedStringResource(
        "app.preferences.general.language.relaunch.failed",
        defaultValue: "MacAMP could not relaunch itself. Quit and open it again to switch language.",
        comment: "Shown when the relaunch button could not restart the app, so the listener does it"
    )
}
