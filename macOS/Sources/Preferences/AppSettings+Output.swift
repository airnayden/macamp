// AppSettings+Output — how `AppSettings.output` reaches and leaves `UserDefaults`.
//
// A sibling file for the mechanical reason `AppSettings+Downloads.swift` and
// `AppSettings+FolderSort.swift` are ones: `AppSettings.swift` sits at `swiftlint
// --strict`'s 400-line ceiling with a single line of headroom, and only declarations
// that own NO stored state may leave it (`@Observable` transforms the primary class
// declaration alone). The stored `output` property therefore stays there; its type,
// its two keys and its hydration live here. Folding a second output preference into
// that file instead would have breached the ceiling and forced another round of
// comment re-flowing — a recurring fight this split ends once.
//
// ── TWO FLAT KEYS, NEVER A BLOB ───────────────────────────────────────────────
//
// `OutputPreferences` is written out as two independent scalars for the reason the
// download family is flat: which device a listener picked and whether it is retuned
// per track are separate choices, and one unreadable value must not reset the other.
// A hand-edited `autoSampleRate` falls back to ON while the chosen device survives.
// The keys are a PERSISTENCE FORMAT — renaming one silently resets what it stored.
//
// ── THE UID IS PERSISTED, THE IDENTIFIER NEVER IS ─────────────────────────────
//
// `OutputDevice.id` is a transient CoreAudio object identifier: it is reused after a
// replug and means nothing across launches. `OutputDevice.uid` is the stable one, so
// it is the only half of a device this file has ever seen. Resolving a UID back to a
// live identifier is `OutputDeviceSnapshot`'s job, and a UID that resolves to nothing
// (the device is unplugged) is KEPT rather than cleared, so replugging restores the
// choice — see `OutputRoutingModel`.
import Foundation

/// Which output device MacAMP plays through, and whether it is retuned per track.
///
/// `deviceUID` is `nil` for "follow the system default", which is both the shipped
/// default and the value a cleared selection returns to — the same `nil` semantics
/// `OutputDeviceSnapshot.selectedUID` uses, so the two never need translating.
public struct OutputPreferences: Equatable, Sendable {
    public var deviceUID: String?
    public var autoSampleRate: Bool

    public init(deviceUID: String? = nil, autoSampleRate: Bool = true) {
        self.deviceUID = deviceUID
        self.autoSampleRate = autoSampleRate
    }
}

extension AppSettings {
    /// Writes both output scalars, from ``output``' `didSet` — so a mutation through
    /// the Output pane's binding persists with no save step.
    func persistOutput() {
        defaults.set(output.deviceUID, forKey: AppSettingsKeys.outputDeviceUID)
        defaults.set(output.autoSampleRate, forKey: AppSettingsKeys.outputAutoSampleRate)
    }

    /// Hydrates the output preferences from `defaults`.
    ///
    /// `static` because `init` calls it before `self` is fully initialized. Each
    /// scalar degrades on its own: a non-string device UID reads back as `nil` (⇒
    /// follow the system default), and the rate switch is read through
    /// `object(forKey:)` rather than `bool(forKey:)` precisely because ABSENT and
    /// `false` must differ here — absent is an install that never chose and must get
    /// the shipped default (ON), whereas `bool(forKey:)` answers `false` for absent
    /// and would ship the feature OFF to every existing install.
    static func loadOutput(from defaults: UserDefaults) -> OutputPreferences {
        OutputPreferences(
            deviceUID: defaults.string(forKey: AppSettingsKeys.outputDeviceUID),
            autoSampleRate: defaults.object(forKey: AppSettingsKeys.outputAutoSampleRate) as? Bool ?? true
        )
    }
}
