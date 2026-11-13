// AppSettingsKeys — every `UserDefaults` key `AppSettings` owns, in one place.
//
// LIFTED OUT OF `AppSettings.swift` for its `swiftlint --strict` `file_length`
// budget (400), the same reason `PreferencesStrings` is spread across seven files.
// Nothing else changed: `AppSettings` keeps a `private typealias Keys =
// AppSettingsKeys`, so all sixty-odd `Keys.foo` references read exactly as before
// and this file is a pure move plus the two playback-control grants.
//
// The keys are a PERSISTENCE FORMAT. Renaming one silently resets whatever it
// stored to its default on the next launch, which for a consent record would mean
// re-asking, and for a grant would mean quietly changing what is allowed.
import Foundation

/// `UserDefaults` keys. Namespaced so they never collide with other domains.
enum AppSettingsKeys {
    static let appearance = "com.example.macamp.settings.appearance"
    static let replayGainMode = "com.example.macamp.settings.replayGainMode"
    static let gaplessEnabled = "com.example.macamp.settings.gaplessEnabled"
    static let defaultEQPresetName = "com.example.macamp.settings.defaultEQPresetName"
    static let defaultVisualizerMode = "com.example.macamp.settings.defaultVisualizerMode"
    static let updateChannel = "com.example.macamp.settings.updateChannel"
    static let showVisualizer = "com.example.macamp.settings.showVisualizer"
    static let themePreset = "com.example.macamp.settings.themePreset"
    static let autoEnrichOnImport = "autoEnrichOnImport"
    static let onlineDataEnabled = "com.example.macamp.settings.onlineDataEnabled"
    static let onlineLyricsEnabled = "com.example.macamp.settings.onlineLyricsEnabled"
    static let profilesEnabled = "com.example.macamp.settings.profilesEnabled"
    static let karaokeEnabled = "com.example.macamp.settings.karaokeEnabled"
    static let karaokeQuality = "com.example.macamp.settings.karaokeQuality"
    static let karaokePruneEnabled = "com.example.macamp.settings.karaokePruneEnabled"
    static let karaokeCacheCapBytes = "com.example.macamp.settings.karaokeCacheCapBytes"
    static let karaokeCacheDirectoryPath = "com.example.macamp.settings.karaokeCacheDirectoryPath"
    static let intelligenceEnabled = "com.example.macamp.settings.ai.intelligenceEnabled"
    static let nlCreationEnabled = "com.example.macamp.settings.ai.nlCreationEnabled"
    static let autoMixesEnabled = "com.example.macamp.settings.ai.autoMixesEnabled"
    static let organizationEnabled = "com.example.macamp.settings.ai.organizationEnabled"
    static let rediscoveryEnabled = "com.example.macamp.settings.ai.rediscoveryEnabled"
    static let insightsEnabled = "com.example.macamp.settings.ai.insightsEnabled"
    static let hygieneEnabled = "com.example.macamp.settings.ai.hygieneEnabled"
    static let connectorSelectedId = "com.example.macamp.settings.ai.connector.selectedId"
    static let connectorSelectedModels = "com.example.macamp.settings.ai.connector.selectedModels"
    static let connectorOllamaHost = "com.example.macamp.settings.ai.connector.ollamaHost"
    static let connectorConsentedIds = "com.example.macamp.settings.ai.connector.consentedIds"
    static let connectorLibraryBrowsingConsentedIds =
        "com.example.macamp.settings.ai.connector.libraryBrowsingConsentedIds"
    static let assistantPlaybackControlEnabled = "com.example.macamp.settings.ai.assistant.playbackControlEnabled"
    static let externalAccessEnabled = "com.example.macamp.settings.ai.externalAccess.enabled"
    static let externalAccessControlEnabled = "com.example.macamp.settings.ai.externalAccess.controlEnabled"
    static let externalAccessPort = "com.example.macamp.settings.ai.externalAccess.port"
    static let externalAccessConsented = "com.example.macamp.settings.ai.externalAccess.consented"
    // MCP CLIENT — the servers MacAMP may CALL OUT to, not the one it serves on
    // `externalAccess…` above. Deliberately a different key family: the two
    // populations are configured, consented and removed independently, and one
    // shared prefix would make a future "reset external access" reach both.
    static let mcpServers = "com.example.macamp.settings.ai.mcp.servers"
    static let mcpConsentedServerIds = "com.example.macamp.settings.ai.mcp.consentedServerIds"
    // WEB SUGGESTIONS — the optional public-web lookups. A family of its own for
    // the reason the two above are: the switch and the disclosure are separate
    // records, and neither may be reached by a reset aimed at the other.
    static let webSuggestionsEnabled = "com.example.macamp.settings.ai.webSuggestions.enabled"
    static let webSuggestionsConsented = "com.example.macamp.settings.ai.webSuggestions.consented"
    // DOWNLOADS — six FLAT SCALAR keys, never one encoded `DownloadPreferences`
    // blob. A blob makes every field an all-or-nothing decode: one unreadable byte
    // would reset the destination folder AND the format AND the quality together.
    // Flat keys degrade one at a time.
    //
    // The family is APPEND-ONLY: the first five below shipped first and their
    // spellings are frozen (renaming one silently resets what it stored), so a new
    // download preference is added as a SIXTH key rather than folded into any of
    // them.
    static let downloadsDestinationPath = "com.example.macamp.settings.downloads.destinationPath"
    static let downloadsAudioFormat = "com.example.macamp.settings.downloads.audioFormat"
    static let downloadsAudioQuality = "com.example.macamp.settings.downloads.audioQuality"
    static let downloadsLastEngineUpdateCheck = "com.example.macamp.settings.downloads.lastEngineUpdateCheck"
    /// Whether a finished download is added to the library. Absent ⇒ `bool(forKey:)`
    /// answers `false`, which IS the shipped default — so an install that predates
    /// this key reads back as OFF without a migration, matching a fresh install.
    static let downloadsAutoImportEnabled = "com.example.macamp.settings.downloads.autoImportEnabled"
    /// How many downloads may transfer at once. Read as an `object(forKey:)` rather
    /// than `integer(forKey:)` precisely because ABSENT and `0` must mean different
    /// things here: absent is a pre-existing install that never chose, and reads back
    /// as `DownloadQueueLimits.defaultConcurrentDownloads`, while a stored `0` is a
    /// value someone wrote and clamps up to 1. `integer(forKey:)` answers `0` for
    /// both and would silently turn every existing install serial.
    static let downloadMaxConcurrent = "com.example.macamp.settings.downloads.maxConcurrent"
    // FOLDER SORT — two flat scalars for the same reason the download family is flat:
    // the sidebar tree and the folder browser are ordered independently, so one
    // unreadable token must not reset the other. Each holds a `FolderSort` /
    // `FolderFilesSort` `rawValue`; an unknown token reads back as that type's
    // `default` rather than trapping, so a downgrade from a future build degrades.
    static let folderTreeSort = "com.example.macamp.settings.folderTreeSort"
    static let folderBrowserSort = "com.example.macamp.settings.folderBrowserSort"
    // OUTPUT — its own flat, APPEND-ONLY family for the reason the download one is:
    // the device a listener picks and whether it is retuned per track are separate
    // choices, so one unreadable value must not reset the other. Read through
    // `object(forKey:)`, NEVER `bool(forKey:)` — absent means "never chose" and must
    // resolve to the shipped default (ON), whereas `bool(forKey:)` answers `false`
    // for absent and would ship the feature OFF to every existing install.
    static let outputAutoSampleRate = "com.example.macamp.settings.output.autoSampleRate"
    /// The chosen device's `OutputDevice.uid` — the STABLE half of a device. Absent
    /// (never written, or cleared back to `nil`) means "follow the system default".
    /// NEVER the `OutputDevice.id`: that identifier is a transient CoreAudio object
    /// number, reused after a replug, so persisting it would route a later launch to
    /// whichever device happened to inherit the number.
    static let outputDeviceUID = "com.example.macamp.settings.output.deviceUID"
    // CROSSFEED — four flat scalars, APPEND-ONLY, flat for the reason the download
    // and output families are: the switch, the preset and the two custom numbers are
    // separate choices, so a hand-edited preset token must degrade to Default without
    // also discarding a carefully dialled custom pair, and vice versa.
    //
    // THE SWITCH IS READ WITH `bool(forKey:)` AND THE NUMBERS ARE NOT, deliberately.
    // Crossfeed ships OFF, so absent ⇒ `false` IS the shipped default and an install
    // predating this key reads back correctly with no migration. The two numbers ship
    // at the Default preset's own values, so they are read through `object(forKey:)`:
    // `double(forKey:)` answers `0` for absent, which `CrossfeedLevel` would then clamp
    // UP to 300 Hz / 1 dB and present as a choice somebody made.
    static let crossfeedEnabled = "com.example.macamp.settings.crossfeed.enabled"
    static let crossfeedPreset = "com.example.macamp.settings.crossfeed.preset"
    static let crossfeedCustomCutFrequency = "com.example.macamp.settings.crossfeed.customCutFrequency"
    static let crossfeedCustomFeedDB = "com.example.macamp.settings.crossfeed.customFeedDB"
    // LANGUAGE — the interface language the listener chose, or ABSENT for "follow the
    // system". A key of our own beside the `AppleLanguages` array macOS actually reads,
    // NOT instead of it: `UserDefaults.standard.object(forKey: "AppleLanguages")` answers
    // from `NSGlobalDomain` when this app has no override, so the resolved read cannot
    // tell "the listener chose English" from "the system is English". Measured — a fresh
    // domain reads back `["en-BG", "bg-BG"]` with nothing of ours written. See
    // `AppLanguageOverride`.
    static let appLanguage = "com.example.macamp.settings.appLanguage"
    static let previewSuite = "com.example.macamp.settings.preview"

    // Single source of key truth: the active/last-active profile ids are owned,
    // read and written exclusively by `ProfileService` (via its injected
    // `UserDefaults`), NOT by `AppSettings`. Documented here so the persisted
    // profile keys live in one place. Do not read/write these from AppSettings.
    //   com.macamp.profiles.activeProfileId
    //   com.macamp.profiles.lastActiveProfileId
}
