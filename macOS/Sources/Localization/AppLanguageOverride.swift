// AppLanguageOverride — reading, writing and clearing the app's language override.
//
// ── THE MECHANISM, AND ITS ONE HONEST LIMITATION ─────────────────────────────
//
// macOS resolves a bundle's localization from the `AppleLanguages` array in the
// app's own `UserDefaults` domain, and it reads it ONCE, at launch. Writing it
// mid-session changes nothing on screen — every `LocalizedStringResource` already
// resolved stays resolved, and `Bundle.main` keeps the localization it opened with.
// So this type only ever changes what the NEXT launch will do, and the pane that
// drives it says so in as many words rather than appearing to do nothing.
//
// ── WHY TWO KEYS ─────────────────────────────────────────────────────────────
//
// `AppleLanguages` is the mechanism; `AppSettingsKeys.appLanguage` is the record of
// what the listener actually chose. They are not redundant, because the resolved
// read is ambiguous: `UserDefaults.standard.object(forKey: "AppleLanguages")` falls
// through to `NSGlobalDomain`, so with nothing of ours written it still answers with
// the system's languages. Measured on a fresh domain: `["en-BG", "bg-BG"]`. Keying
// the picker off that would make "System" indistinguishable from a listener who
// picked the language the system happens to already use.
//
// "System" therefore REMOVES both keys rather than writing one. Writing a resolved
// system language instead would freeze the app to whatever the system said on the
// day the listener opened this pane, and it could never follow the system again.
import AppKit
import Foundation

/// Reads and writes the interface-language override macOS applies at launch.
public enum AppLanguageOverride {
    /// The array macOS itself reads. Not ours to rename.
    static let appleLanguagesKey = "AppleLanguages"

    /// The chosen language, or `nil` when the app follows the system.
    public static func current(in defaults: UserDefaults = .standard) -> AppLanguage? {
        defaults.string(forKey: AppSettingsKeys.appLanguage).flatMap(AppLanguage.init(rawValue:))
    }

    /// What `apply(_:in:)` writes to `AppleLanguages` for `language` — `nil` meaning
    /// REMOVE the key rather than write anything.
    ///
    /// Split out as a pure function so "System clears the override instead of pinning
    /// one" is an invariant a test can state directly, rather than something inferred
    /// from the absence of a write.
    public static func appleLanguagesValue(for language: AppLanguage?) -> [String]? {
        language.map { [$0.rawValue] }
    }

    /// Records `language` as the interface language, or clears the override for `nil`.
    ///
    /// A single-element array is enough: an unlocalized key falls back to the
    /// development region on its own, so listing a fallback language would only
    /// change which language a MISSING string appears in, never whether one appears.
    public static func apply(_ language: AppLanguage?, in defaults: UserDefaults = .standard) {
        guard let language, let value = appleLanguagesValue(for: language) else {
            defaults.removeObject(forKey: AppSettingsKeys.appLanguage)
            defaults.removeObject(forKey: appleLanguagesKey)
            return
        }
        defaults.set(language.rawValue, forKey: AppSettingsKeys.appLanguage)
        defaults.set(value, forKey: appleLanguagesKey)
    }
}

// MARK: - Relaunch

public extension AppLanguageOverride {
    /// Quits MacAMP and opens it again, so the language written above takes effect.
    ///
    /// The quit is CONDITIONAL on the helper having spawned. A button that terminates
    /// the app and then fails to bring it back is strictly worse than one that does
    /// nothing, so a failed spawn leaves the app running and the caller shows the
    /// "next time it starts" caption it was always going to show anyway.
    ///
    /// `open` is delayed because it refuses to start a second instance of a bundle
    /// that is still running: without the pause it would simply re-activate the
    /// window of the app that is in the middle of quitting. The path travels as `$0`
    /// rather than interpolated into the script, so a bundle path containing a quote
    /// or a space cannot become shell syntax.
    @MainActor
    @discardableResult
    static func relaunch(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", #"sleep 1; exec /usr/bin/open "$0""#, bundlePath]
        do {
            try relauncher.run()
        } catch {
            return false
        }
        NSApplication.shared.terminate(nil)
        return true
    }
}
