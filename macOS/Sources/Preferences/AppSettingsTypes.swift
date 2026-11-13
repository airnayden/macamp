// AppSettingsTypes — the value types `AppSettings`'s stored properties are spelled in.
//
// Moved out of `AppSettings.swift` verbatim, for one mechanical reason: that file
// stood at EXACTLY 400 lines, which is `swiftlint --strict`'s `file_length` ceiling,
// so the connector-consent property could not be added without freeing space first.
// The precedent is `AppSettings+DesignTokens.swift`, split off for the same reason.
//
// Only declarations that own NO stored state may move. `@Observable` transforms the
// primary class declaration alone, so every stored property — and therefore the
// whole class body — has to stay where it is.
import Foundation
import SwiftUI

// MARK: - ThemePreset

/// MacAMP ships exactly one skin. The enum is retained (rather than dropped for a
/// bare constant) so the persisted `rawValue`, the archive payload, and the
/// preferences picker all keep their existing shapes — and so a second skin costs
/// one `case` rather than a schema change.
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
    /// would survive on disk and every future read would re-migrate it.
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
/// `SparkleUpdaterDelegate` translates this into Sparkle's `allowedChannels(for:)`,
/// whose names must match the `--channel` tags `scripts/make-appcast.sh` writes.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    /// Shipping releases only.
    case stable
    /// Pre-release builds.
    case beta

    public var id: String {
        rawValue
    }
}

// MARK: - KaraokeCacheDirectoryChangeResult

/// The outcome of relocating the karaoke instrumental cache to a new directory.
///
/// Returned by ``AppSettings/changeKaraokeCacheDirectory`` so the preferences pane
/// can report what happened (the actual relocation logic is wired in later).
public enum KaraokeCacheDirectoryChangeResult: Sendable {
    /// The cache's existing contents were moved to the chosen directory.
    case moved
    /// The chosen directory was adopted but started empty (contents not moved).
    case freshStart
    /// The chosen directory was rejected (e.g. it is inside a library root or the
    /// cache's own tree); `reason` explains why.
    case rejected(reason: String)
    /// The relocation failed (an I/O error occurred).
    case failed
}
