// CrossfeedPreferences — the listener's crossfeed choices, and how they reach and
// leave `UserDefaults`.
//
// ── WHY THIS IS NOT A PROPERTY ON `AppSettings` ──────────────────────────────
//
// Two reasons, and either alone would be enough.
//
// 1. Crossfeed is a LIVE ENGINE PARAMETER, not a launch default. Every write has to
//    reach `PlaybackEngine.setCrossfeed(enabled:fcut:feedDB:)` on the way past, which
//    is the same shape as choosing an output device — and `OutputPreferencesPane`'s
//    device picker already binds to `OutputRoutingModel` rather than to `AppSettings`
//    for exactly that reason. `AppSettings` has no push mechanism; the seven optional
//    `onKaraoke…` closures bolted onto it are what happens when one is improvised.
// 2. `AppSettings.swift` sits at 399 of SwiftLint's 400-line `file_length` ceiling
//    with a 49-of-50-line initializer. The recorded escape (issues.md, todo 15) is to
//    extract an EXISTING family into a struct, which frees lines only when it replaces
//    something — a fifth family adds six lines it does not have.
//
// The keys still live in `AppSettingsKeys`, which stays the single source of key
// truth, exactly as `ProfileService`'s own keys are recorded there.
//
// ── THE RANGES AND THE CLAMP BELONG TO `CrossfeedLevel` ──────────────────────
//
// `CrossfeedLevel.cutFrequencyRange` (300…2000 Hz) and `.feedRange` (1…15 dB) are the
// slider bounds, and `CrossfeedLevel`'s initialiser clamps PER COMPONENT — so a stale
// or hand-edited value is honoured on the component that WAS legal instead of being
// discarded wholesale. Nothing here re-implements either; ``customLevel`` is the one
// way a raw stored pair becomes a legal one.
import DSP
import Foundation

/// The crossfeed strength a listener picked: one of bs2b's three published settings,
/// or a hand-dialled pair.
///
/// The raw values are a PERSISTENCE FORMAT: renaming a case silently resets every
/// listener's choice to Default, so the four spellings here are frozen. They are the
/// same tokens `CrossfeedLevel` names its three published settings by.
enum CrossfeedPreset: String, CaseIterable, Hashable {
    case `default`
    case cmoy
    case jmeier
    case custom
}

/// Whether crossfeed is in the signal path, and at what strength.
struct CrossfeedPreferences: Equatable {
    var isEnabled: Bool
    var preset: CrossfeedPreset
    var customCutFrequency: Double
    var customFeedDB: Double

    init(
        isEnabled: Bool = false,
        preset: CrossfeedPreset = .default,
        customCutFrequency: Double = CrossfeedLevel.default.cutFrequency,
        customFeedDB: Double = CrossfeedLevel.default.feedDB
    ) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.customCutFrequency = customCutFrequency
        self.customFeedDB = customFeedDB
    }
}

extension CrossfeedPreferences {
    /// The custom pair as a legal level. Reading the sliders back through this is what
    /// keeps a stored value that is out of range from ever reaching a `Slider` whose
    /// bounds would not accept it.
    var customLevel: CrossfeedLevel {
        CrossfeedLevel(cutFrequency: customCutFrequency, feedDB: customFeedDB)
    }

    /// The level the engine is asked for, whichever preset is selected.
    var resolvedLevel: CrossfeedLevel {
        switch preset {
        case .default: CrossfeedLevel.default
        case .cmoy: CrossfeedLevel.cmoy
        case .jmeier: CrossfeedLevel.jmeier
        case .custom: customLevel
        }
    }
}

extension CrossfeedPreferences {
    /// Hydrates from `defaults`, degrading each scalar on its own.
    static func load(from defaults: UserDefaults) -> CrossfeedPreferences {
        CrossfeedPreferences(
            isEnabled: defaults.bool(forKey: AppSettingsKeys.crossfeedEnabled),
            preset: CrossfeedPreset(rawValue: defaults.string(forKey: AppSettingsKeys.crossfeedPreset) ?? "")
                ?? .default,
            customCutFrequency: defaults.object(forKey: AppSettingsKeys.crossfeedCustomCutFrequency) as? Double
                ?? CrossfeedLevel.default.cutFrequency,
            customFeedDB: defaults.object(forKey: AppSettingsKeys.crossfeedCustomFeedDB) as? Double
                ?? CrossfeedLevel.default.feedDB
        )
    }

    /// Writes all four scalars.
    func persist(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: AppSettingsKeys.crossfeedEnabled)
        defaults.set(preset.rawValue, forKey: AppSettingsKeys.crossfeedPreset)
        defaults.set(customCutFrequency, forKey: AppSettingsKeys.crossfeedCustomCutFrequency)
        defaults.set(customFeedDB, forKey: AppSettingsKeys.crossfeedCustomFeedDB)
    }
}
