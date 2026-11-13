// PortableSettingsMapping — the `AppSettings ⇄ PortableSettings` bridge.
//
// PlayerCore cannot see `AppSettings` (a `@MainActor` UserDefaults store that lives
// only in this shell), so the archive codec carries the machine-independent
// preferences as a flat, all-optional `PortableSettings` and the SHELL owns the
// mapping. That seam is why the codec is testable without a UI layer.
//
// Two rules this file exists to enforce:
//   * Enum-valued preferences travel as their `rawValue`, and an unrecognised raw
//     value on the way back in is IGNORED rather than coerced to a default — an
//     archive from a build with an extra theme must not silently reset the theme.
//   * A `nil` field means "the archive did not say", so ``apply(to:)`` leaves that
//     preference exactly as the user had it.
import Foundation
import Persistence
import Separation
import Services
import Visualizer

extension PortableSettings {
    /// Snapshots the machine-independent preferences.
    ///
    /// `karaokeCacheDirectoryPath`, window geometry and `profilesEnabled` are
    /// deliberately absent: the first is an absolute path on this Mac, the others
    /// are per-install state that would be wrong anywhere else.
    @MainActor
    init(_ settings: AppSettings) {
        self.init(
            appearance: settings.appearance.rawValue,
            replayGainMode: settings.replayGainMode.rawValue,
            gaplessEnabled: settings.gaplessEnabled,
            defaultEQPresetName: settings.defaultEQPresetName,
            defaultVisualizerMode: settings.defaultVisualizerMode.rawValue,
            showVisualizer: settings.showVisualizer,
            themePreset: settings.themePreset.rawValue,
            updateChannel: settings.updateChannel.rawValue,
            autoEnrichOnImport: settings.autoEnrichOnImport,
            onlineDataEnabled: settings.onlineDataEnabled,
            onlineLyricsEnabled: settings.onlineLyricsEnabled,
            karaokeEnabled: settings.karaokeEnabled,
            karaokeQuality: settings.karaokeQuality.rawValue,
            karaokePruneEnabled: settings.karaokePruneEnabled,
            karaokeCacheCapBytes: settings.karaokeCacheCapBytes
        )
    }

    /// Applies every preference the archive actually carried, leaving the rest alone.
    @MainActor
    func apply(to settings: AppSettings) {
        applyAppearanceAndTheme(to: settings)
        applyPlayback(to: settings)
        applyOnline(to: settings)
        applyKaraoke(to: settings)
    }
}

private extension PortableSettings {
    @MainActor
    func applyAppearanceAndTheme(to settings: AppSettings) {
        if let raw = appearance, let value = AppearanceSetting(rawValue: raw) {
            settings.appearance = value
        }
        // The skin is the ONE exception to the ignore-unknown-rawValue rule above:
        // MacAMP ships exactly one, so an archive naming any other ("viceCity",
        // "purple", …) is a legacy archive, not a richer build — mapping it is a
        // migration, and skipping it would leave the field silently unapplied.
        if themePreset != nil {
            settings.themePreset = .macAMP
        }
        if let raw = updateChannel, let value = UpdateChannel(rawValue: raw) {
            settings.updateChannel = value
        }
    }

    @MainActor
    func applyPlayback(to settings: AppSettings) {
        if let raw = replayGainMode, let value = ReplayGainMode(rawValue: raw) {
            settings.replayGainMode = value
        }
        if let gaplessEnabled {
            settings.gaplessEnabled = gaplessEnabled
        }
        if let defaultEQPresetName {
            settings.defaultEQPresetName = defaultEQPresetName
        }
        if let raw = defaultVisualizerMode, let value = VisualizerMode(rawValue: raw) {
            settings.defaultVisualizerMode = value
        }
        if let showVisualizer {
            settings.showVisualizer = showVisualizer
        }
    }

    @MainActor
    func applyOnline(to settings: AppSettings) {
        if let autoEnrichOnImport {
            settings.autoEnrichOnImport = autoEnrichOnImport
        }
        if let onlineDataEnabled {
            settings.onlineDataEnabled = onlineDataEnabled
        }
        if let onlineLyricsEnabled {
            settings.onlineLyricsEnabled = onlineLyricsEnabled
        }
    }

    @MainActor
    func applyKaraoke(to settings: AppSettings) {
        if let karaokeEnabled {
            settings.karaokeEnabled = karaokeEnabled
        }
        if let raw = karaokeQuality, let value = InstrumentalRenderQuality(rawValue: raw) {
            settings.karaokeQuality = value
        }
        if let karaokePruneEnabled {
            settings.karaokePruneEnabled = karaokePruneEnabled
        }
        if let karaokeCacheCapBytes {
            settings.karaokeCacheCapBytes = karaokeCacheCapBytes
        }
    }
}
