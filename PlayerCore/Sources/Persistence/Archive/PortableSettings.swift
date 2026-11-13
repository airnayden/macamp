// PortableSettings — the machine-independent slice of the user's preferences that
// travels inside a `.macampprofile` archive.
//
// This type deliberately knows NOTHING about the macOS shell's `AppSettings` (a
// `@MainActor` UserDefaults wrapper that PlayerCore cannot import, and must not).
// Enum-valued preferences are carried as their raw `String`s, so the
// `AppSettings ⇄ PortableSettings` mapping lives in the SHELL, in both directions,
// and the codec stays portable and testable without a UI layer.
//
// Foundation only — no AppKit/UIKit (PlayerCore portability invariant).
import Foundation

/// A snapshot of the preferences that mean the same thing on any machine.
///
/// **Every field is optional and every unknown key is ignored on decode**, so an
/// archive written by an older or newer build still imports losslessly: an absent
/// key stays `nil` and the shell simply leaves that preference untouched.
///
/// ## What is deliberately NOT here
/// Machine-local state is excluded by construction, not by filtering:
/// * `karaokeCacheDirectoryPath` — an absolute path on the exporting machine.
/// * Window frames / sidebar geometry — meaningless on another display.
/// * `profilesEnabled` — a per-install feature flag, not a portable preference.
///
/// Adding a field here is a schema change: keep it optional, and bump
/// ``ProfileArchive/currentVersion`` only if the MEANING of an existing field
/// changes (a new optional field needs no bump — old readers ignore it, new
/// readers see `nil`).
public struct PortableSettings: Codable, Sendable, Equatable, Hashable {
    /// Raw value of the shell's appearance setting (light / dark / system).
    public var appearance: String?
    /// Raw value of the ReplayGain mode.
    public var replayGainMode: String?
    /// Whether gapless playback is on.
    public var gaplessEnabled: Bool?
    /// Name of the EQ preset applied at launch. Resolves against the built-ins and
    /// the custom presets carried in ``ProfileArchive/eqPresets``.
    public var defaultEQPresetName: String?
    /// Raw value of the default visualizer mode.
    public var defaultVisualizerMode: String?
    /// Whether the inline visualizer is shown.
    public var showVisualizer: Bool?
    /// Raw value of the colour theme preset.
    public var themePreset: String?
    /// Raw value of the update channel.
    public var updateChannel: String?
    /// Whether imports auto-enrich metadata.
    public var autoEnrichOnImport: Bool?
    /// Whether online metadata lookups are allowed.
    public var onlineDataEnabled: Bool?
    /// Whether online lyrics lookups are allowed.
    public var onlineLyricsEnabled: Bool?
    /// Whether karaoke mode is available.
    public var karaokeEnabled: Bool?
    /// Raw value of the instrumental render quality.
    public var karaokeQuality: String?
    /// Whether the instrumental cache prunes itself.
    public var karaokePruneEnabled: Bool?
    /// Instrumental cache ceiling in bytes. A size, not a location — portable.
    public var karaokeCacheCapBytes: Int64?

    public init(
        appearance: String? = nil,
        replayGainMode: String? = nil,
        gaplessEnabled: Bool? = nil,
        defaultEQPresetName: String? = nil,
        defaultVisualizerMode: String? = nil,
        showVisualizer: Bool? = nil,
        themePreset: String? = nil,
        updateChannel: String? = nil,
        autoEnrichOnImport: Bool? = nil,
        onlineDataEnabled: Bool? = nil,
        onlineLyricsEnabled: Bool? = nil,
        karaokeEnabled: Bool? = nil,
        karaokeQuality: String? = nil,
        karaokePruneEnabled: Bool? = nil,
        karaokeCacheCapBytes: Int64? = nil
    ) {
        self.appearance = appearance
        self.replayGainMode = replayGainMode
        self.gaplessEnabled = gaplessEnabled
        self.defaultEQPresetName = defaultEQPresetName
        self.defaultVisualizerMode = defaultVisualizerMode
        self.showVisualizer = showVisualizer
        self.themePreset = themePreset
        self.updateChannel = updateChannel
        self.autoEnrichOnImport = autoEnrichOnImport
        self.onlineDataEnabled = onlineDataEnabled
        self.onlineLyricsEnabled = onlineLyricsEnabled
        self.karaokeEnabled = karaokeEnabled
        self.karaokeQuality = karaokeQuality
        self.karaokePruneEnabled = karaokePruneEnabled
        self.karaokeCacheCapBytes = karaokeCacheCapBytes
    }
}
