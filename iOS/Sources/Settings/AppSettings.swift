// AppSettings — the iOS shell's user-preference store.
//
// Every value the Settings screen edits lives here, persisted to the App Group
// `UserDefaults` suite (shared with the widget). The type is `@Observable` so
// SwiftUI panes bind to it with `@Bindable` and a single shared instance is
// injected through the environment.
//
// Each stored property writes through to `UserDefaults` in its `didSet`; the
// initializer hydrates from `UserDefaults` (assignments in `init` do not fire
// `didSet`, so hydration never redundantly writes back). `UserDefaults` is not
// `Sendable`, but this type is `@MainActor`, so holding the resolved suite is
// safe. A volatile suite can be injected for previews/tests.
//
// This is app-shell code: importing SwiftUI/UIKit-adjacent types here is fine
// (the AppKit/UIKit ban applies only to PlayerCore).
import DesignSystem
import Foundation
import Models
import Observation
import Persistence
import Services
import SwiftUI
import Visualizer

// MARK: - ThemePreset

/// MacAMP ships exactly one skin. The enum is retained (rather than dropped for a
/// bare constant) so the persisted `rawValue` and the design-token switch keep their
/// existing shapes — and so a second skin costs one `case` rather than a schema
/// change. Declared independently of the macOS shell's identically-named enum: the
/// two shells hold separate preference stores and neither imports the other.
public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case macAMP

    public var id: String {
        rawValue
    }

    /// Resolves the persisted preference, rewriting any legacy skin id (`viceCity`,
    /// `purple`, `midnight`, …), any unrecognised value, and a missing value to the
    /// one shipped skin.
    ///
    /// The write-back is explicit because `AppSettings` hydrates in `init`, where
    /// the stored property's `didSet` never fires — without it the stale string
    /// would survive in the App Group suite and every launch would re-migrate it.
    static func migratingStoredValue(in defaults: UserDefaults, forKey key: String) -> ThemePreset {
        if defaults.string(forKey: key) != ThemePreset.macAMP.rawValue {
            defaults.set(ThemePreset.macAMP.rawValue, forKey: key)
        }
        return .macAMP
    }
}

// MARK: - AppearanceSetting

/// The user's preferred window appearance.
public enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system Light/Dark setting.
    case system
    /// Force Light.
    case light
    /// Force Dark.
    case dark

    public var id: String {
        rawValue
    }

    /// The SwiftUI color scheme to force, or `nil` to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - UpdateChannel

/// The Sparkle update feed the user opts into.
///
/// Sparkle itself is wired in a later task (Task 38); this is the persisted
/// preference the eventual updater will read.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    /// Shipping releases only.
    case stable
    /// Pre-release builds.
    case beta

    public var id: String {
        rawValue
    }
}

// MARK: - AppSettings

/// The observable, App-Group `UserDefaults`-backed preference store for the iOS shell.
@MainActor
@Observable
public final class AppSettings {
    /// Preferred window appearance (Light / Dark / System).
    public var appearance: AppearanceSetting {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Default ReplayGain normalization reference applied at launch.
    public var replayGainMode: ReplayGainMode {
        didSet { defaults.set(replayGainMode.rawValue, forKey: Keys.replayGainMode) }
    }

    /// Whether gapless continuation between queued tracks is enabled.
    public var gaplessEnabled: Bool {
        didSet { defaults.set(gaplessEnabled, forKey: Keys.gaplessEnabled) }
    }

    /// Name of the EQ preset applied at launch.
    public var defaultEQPresetName: String {
        didSet { defaults.set(defaultEQPresetName, forKey: Keys.defaultEQPresetName) }
    }

    /// Visualizer mode shown when the visualizer first opens.
    public var defaultVisualizerMode: VisualizerMode {
        didSet { defaults.set(defaultVisualizerMode.rawValue, forKey: Keys.defaultVisualizerMode) }
    }

    /// Sparkle update channel (consumed by the future updater, Task 38).
    public var updateChannel: UpdateChannel {
        didSet { defaults.set(updateChannel.rawValue, forKey: Keys.updateChannel) }
    }

    /// Whether the inline spectrum visualizer is shown in the player bar.
    public var showVisualizer: Bool {
        didSet { defaults.set(showVisualizer, forKey: Keys.showVisualizer) }
    }

    /// Whether imported tracks are auto-enriched from the online metadata source.
    public var autoEnrichOnImport: Bool {
        didSet { defaults.set(autoEnrichOnImport, forKey: Keys.autoEnrichOnImport) }
    }

    /// The accent-color preset applied to the design tokens.
    public var themePreset: ThemePreset {
        didSet { defaults.set(themePreset.rawValue, forKey: Keys.themePreset) }
    }

    // MARK: Intelligence (local AI)

    // iOS ships the read-only half of the feature — generator-backed playlists —
    // so only three of `AISettingsProviding`'s seven switches are real, stored
    // preferences here. The other four are constant `false`: there is no assistant,
    // no organisation UI, no insights card and no hygiene surface on this shell, so
    // a stored key would persist a promise nothing keeps. This store is the App
    // Group suite, separate from the macOS one by design — the two shells hold
    // independent preferences.

    /// The master switch. `false` ⇒ no AI service is constructed at all.
    public var intelligenceEnabled: Bool {
        didSet { defaults.set(intelligenceEnabled, forKey: Keys.intelligenceEnabled) }
    }

    /// Standing generated mixes (`AIFeatureBundle.autoMixes`).
    public var autoMixesEnabled: Bool {
        didSet { defaults.set(autoMixesEnabled, forKey: Keys.autoMixesEnabled) }
    }

    /// Rediscovery surfacing (`AIFeatureBundle.rediscovery`).
    public var rediscoveryEnabled: Bool {
        didSet { defaults.set(rediscoveryEnabled, forKey: Keys.rediscoveryEnabled) }
    }

    /// Always `false`: the iOS shell has no natural-language assistant surface.
    public var nlCreationEnabled: Bool {
        false
    }

    /// Always `false`: the iOS shell has no organisation surface.
    public var organizationEnabled: Bool {
        false
    }

    /// Always `false`: the iOS shell has no listening-insights surface.
    public var insightsEnabled: Bool {
        false
    }

    /// Always `false`: the iOS shell has no library-hygiene surface.
    public var hygieneEnabled: Bool {
        false
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Creates a settings store backed by `defaults` (App Group suite in the app).
    public init(defaults: UserDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard) {
        self.defaults = defaults
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        replayGainMode = ReplayGainMode(rawValue: defaults.string(forKey: Keys.replayGainMode) ?? "") ?? .off
        gaplessEnabled = defaults.object(forKey: Keys.gaplessEnabled) as? Bool ?? true
        defaultEQPresetName = defaults.string(forKey: Keys.defaultEQPresetName) ?? EQPreset.flat.name
        defaultVisualizerMode = VisualizerMode(rawValue: defaults.string(forKey: Keys.defaultVisualizerMode) ?? "")
            ?? .bars
        updateChannel = UpdateChannel(rawValue: defaults.string(forKey: Keys.updateChannel) ?? "") ?? .stable
        showVisualizer = defaults.object(forKey: Keys.showVisualizer) as? Bool ?? true
        autoEnrichOnImport = defaults.object(forKey: Keys.autoEnrichOnImport) as? Bool ?? false
        themePreset = ThemePreset.migratingStoredValue(in: defaults, forKey: Keys.themePreset)
        intelligenceEnabled = defaults.object(forKey: Keys.intelligenceEnabled) as? Bool ?? true
        autoMixesEnabled = defaults.object(forKey: Keys.autoMixesEnabled) as? Bool ?? true
        rediscoveryEnabled = defaults.object(forKey: Keys.rediscoveryEnabled) as? Bool ?? true
    }

    public var designTokens: DesignTokens {
        switch themePreset {
        case .macAMP:
            DesignTokens(
                colors: .macAMP,
                spacing: .standard, typography: .standard, radii: .standard, elevation: .standard, motion: .standard
            )
        }
    }

    public static var preview: AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: Keys.previewSuite) ?? .standard)
    }

    /// `UserDefaults` keys. Namespaced so they never collide with other domains.
    private enum Keys {
        static let appearance = "com.example.macamp.settings.appearance"
        static let replayGainMode = "com.example.macamp.settings.replayGainMode"
        static let gaplessEnabled = "com.example.macamp.settings.gaplessEnabled"
        static let defaultEQPresetName = "com.example.macamp.settings.defaultEQPresetName"
        static let defaultVisualizerMode = "com.example.macamp.settings.defaultVisualizerMode"
        static let updateChannel = "com.example.macamp.settings.updateChannel"
        static let showVisualizer = "com.example.macamp.settings.showVisualizer"
        static let autoEnrichOnImport = "com.example.macamp.settings.autoEnrichOnImport"
        static let themePreset = "com.example.macamp.settings.themePreset"
        static let intelligenceEnabled = "com.example.macamp.settings.ai.intelligenceEnabled"
        static let autoMixesEnabled = "com.example.macamp.settings.ai.autoMixesEnabled"
        static let rediscoveryEnabled = "com.example.macamp.settings.ai.rediscoveryEnabled"
        static let previewSuite = "com.example.macamp.settings.preview"
    }
}

// MARK: - AISettingsProviding

/// Three stored switches plus four constant `false`s satisfy every requirement; the
/// protocol is `@MainActor` exactly so this type can witness them (Task 19).
extension AppSettings: AISettingsProviding {}
