// KaraokePreferencesStrings — user-facing copy for the Karaoke settings pane.
//
// Split out of `PreferencesStrings` (which crossed the 400-line file ceiling) so
// the Karaoke pane's copy lives beside the pane. Same conventions as its parent:
// each label is a `LocalizedStringResource` with an English `defaultValue` and a
// dotted key, which are the single handoff list for Task 44's translations.
import Foundation

extension PreferencesStrings {
    static let karaoke = LocalizedStringResource(
        "settings.playback.karaoke.toggle",
        defaultValue: "Karaoke mode",
        comment: "Toggle that enables karaoke (vocal-removal) mode and background pre-warming of instrumentals"
    )
    static let karaokeCaption = LocalizedStringResource(
        "settings.playback.karaoke.caption",
        defaultValue: "Remove vocals from your tracks. Instrumentals are prepared in the background and cached on disk.",
        comment: "Explains the karaoke-mode toggle"
    )
    static let karaokeCacheSize = LocalizedStringResource(
        "settings.playback.karaoke.cacheSize",
        defaultValue: "Cached instrumentals",
        comment: "Label for the readout showing how much disk the cached karaoke instrumentals use"
    )
    static let karaokeClearCache = LocalizedStringResource(
        "settings.playback.karaoke.clearCache",
        defaultValue: "Clear Karaoke Cache",
        comment: "Button that deletes all cached karaoke instrumental files from disk"
    )
    static let tabKaraoke = LocalizedStringResource(
        "app.preferences.tab.karaoke",
        defaultValue: "Karaoke",
        comment: "Preferences tab: karaoke vocal-removal options"
    )
    static let karaokeSubtitle = LocalizedStringResource(
        "app.preferences.karaoke.subtitle",
        defaultValue: "Remove vocals so you can sing along.",
        comment: "One-line subtitle under the Karaoke preferences pane title"
    )
    static let karaokeUnavailable = LocalizedStringResource(
        "app.preferences.karaoke.unavailable",
        defaultValue: "The vocal-removal model isn't available in this build, so karaoke can't run.",
        comment: "Notice shown when karaoke is on but the separation model is missing or the system is too old"
    )
    static let karaokeQuality = LocalizedStringResource(
        "app.preferences.karaoke.quality",
        defaultValue: "Instrumental quality",
        comment: "Label for the picker choosing the karaoke instrumental encode quality"
    )
    static let karaokeQualityStandard = LocalizedStringResource(
        "app.preferences.karaoke.quality.standard",
        defaultValue: "Standard (AAC 256 kbps)",
        comment: "Karaoke quality option: 256 kbps AAC, smaller cached files"
    )
    static let karaokeQualityLossless = LocalizedStringResource(
        "app.preferences.karaoke.quality.lossless",
        defaultValue: "High (Lossless)",
        comment: "Karaoke quality option: lossless ALAC, larger cached files"
    )
    static let karaokeQualityCaption = LocalizedStringResource(
        "app.preferences.karaoke.quality.caption",
        defaultValue: "Applies to newly created karaoke versions. Instrumentals already cached at another quality are unaffected.",
        comment: "Explains that the karaoke quality choice only affects newly rendered instrumentals"
    )
    static let karaokeCacheDirectory = LocalizedStringResource(
        "app.preferences.karaoke.cacheDirectory",
        defaultValue: "Cache location",
        comment: "Label for the readout showing where karaoke instrumentals are cached on disk"
    )
    static let karaokeChooseDirectory = LocalizedStringResource(
        "app.preferences.karaoke.cacheDirectory.choose",
        defaultValue: "Choose…",
        comment: "Button that opens a folder picker to choose the karaoke cache location"
    )
    static let karaokeResetDirectory = LocalizedStringResource(
        "app.preferences.karaoke.cacheDirectory.reset",
        defaultValue: "Reset to Default",
        comment: "Button that resets the karaoke cache location to the default directory"
    )
    static let karaokeCacheFreshStart = LocalizedStringResource(
        "app.preferences.karaoke.cacheDirectory.freshStart",
        defaultValue: "Using the new location. Previously cached instrumentals will be recreated as needed.",
        comment: "Notice shown after choosing a new, empty karaoke cache location"
    )
    static let karaokeCacheChangeFailed = LocalizedStringResource(
        "app.preferences.karaoke.cacheDirectory.failed",
        defaultValue: "Couldn't move the cache to that location. Try a different folder.",
        comment: "Error shown when relocating the karaoke cache directory fails"
    )
    static let karaokePrune = LocalizedStringResource(
        "app.preferences.karaoke.prune",
        defaultValue: "Limit cache size",
        comment: "Toggle that caps the karaoke instrumental cache and auto-removes old files"
    )
    static let karaokePruneCaption = LocalizedStringResource(
        "app.preferences.karaoke.prune.caption",
        defaultValue: "Automatically remove the least-recently-used instrumentals to stay under the size limit.",
        comment: "Explains the karaoke cache-size-limit toggle"
    )
    static let karaokeCacheCap = LocalizedStringResource(
        "app.preferences.karaoke.cacheCap",
        defaultValue: "Maximum size",
        comment: "Label for the picker choosing the karaoke cache's maximum on-disk size"
    )
}
