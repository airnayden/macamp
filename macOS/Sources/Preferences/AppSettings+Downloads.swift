// AppSettings+Downloads — how `AppSettings.downloads` reaches and leaves `UserDefaults`.
//
// A sibling file for the mechanical reason `AppSettingsTypes.swift` and
// `AppSettings+Accessors.swift` are: `AppSettings.swift` sits at `swiftlint
// --strict`'s 400-line ceiling, and only declarations that own NO stored state may
// leave it (`@Observable` transforms the primary class declaration alone).
//
// ── SIX FLAT KEYS, NEVER A BLOB ───────────────────────────────────────────────
//
// `DownloadPreferences` is written out as six independent scalars, not as one
// encoded value. A blob would make every field an all-or-nothing decode: a single
// unreadable byte would reset the destination folder AND the format AND the quality
// together. Flat keys degrade one at a time — a hand-edited `audioFormat` falls back
// to `.m4a` while the chosen destination survives untouched. The keys themselves are
// a PERSISTENCE FORMAT: renaming one silently resets what it stored.
//
// `AppSettings.defaults` is internal rather than private precisely so
// ``persistDownloads()`` can reach it from here — Swift scopes `private` to the
// declaring file, and the whole point of this file is to be a different one.
import Foundation
import Services

extension AppSettings {
    /// Writes the six download scalars, from ``downloads``' `didSet` — so a
    /// mutation through the pane's binding persists with no save step.
    func persistDownloads() {
        defaults.set(downloads.destinationPath, forKey: AppSettingsKeys.downloadsDestinationPath)
        defaults.set(downloads.audioFormat.rawValue, forKey: AppSettingsKeys.downloadsAudioFormat)
        defaults.set(downloads.audioQuality.rawValue, forKey: AppSettingsKeys.downloadsAudioQuality)
        defaults.set(downloads.lastEngineUpdateCheck, forKey: AppSettingsKeys.downloadsLastEngineUpdateCheck)
        defaults.set(downloads.autoImportEnabled, forKey: AppSettingsKeys.downloadsAutoImportEnabled)
        defaults.set(downloads.maxConcurrent, forKey: AppSettingsKeys.downloadMaxConcurrent)
    }

    /// Hydrates the download preferences from `defaults`.
    ///
    /// `static` because `init` calls it before `self` is fully initialized. Each
    /// scalar degrades on its own rather than trapping: an unknown format or quality
    /// token reads back as that enum's `default`, a non-string destination as `nil`
    /// (⇒ the default directory), a non-date stamp as "never checked", and anything
    /// that is not a stored `true` as auto-import OFF — which is also what an install
    /// predating the key reads back as, so the switch needs no migration — and an
    /// absent or non-numeric concurrency as the shipped default, while a numeric one
    /// outside `1...4` is CLAMPED rather than discarded (a stored `9` means "as many
    /// as you can", and answering that with `3` would be a worse reading than `4`).
    static func loadDownloads(from defaults: UserDefaults) -> DownloadPreferences {
        DownloadPreferences(
            destinationPath: defaults.string(forKey: AppSettingsKeys.downloadsDestinationPath),
            audioFormat: DownloadAudioFormat(
                rawValue: defaults.string(forKey: AppSettingsKeys.downloadsAudioFormat) ?? ""
            ) ?? .default,
            audioQuality: DownloadAudioQuality(
                rawValue: defaults.string(forKey: AppSettingsKeys.downloadsAudioQuality) ?? ""
            ) ?? .default,
            lastEngineUpdateCheck: defaults
                .object(forKey: AppSettingsKeys.downloadsLastEngineUpdateCheck) as? Date,
            autoImportEnabled: defaults.bool(forKey: AppSettingsKeys.downloadsAutoImportEnabled),
            maxConcurrent: defaults.object(forKey: AppSettingsKeys.downloadMaxConcurrent) as? Int
                ?? DownloadQueueLimits.defaultConcurrentDownloads
        )
    }
}
