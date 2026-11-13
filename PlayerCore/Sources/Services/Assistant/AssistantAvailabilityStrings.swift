// AssistantAvailabilityStrings — the user-facing copy for every reason the
// on-device assistant is unavailable.
//
// Centralized as `LocalizedStringResource` keys with an English `defaultValue`,
// exactly like `SeparationStrings` (PlayerCore/Sources/Separation/SeparationStrings.swift).
// The module never emits a bare literal — ``AssistantUnavailableReason/message``
// references these constants — so it is localization-clean by construction and
// AppKit/UIKit-free (PlayerCore portability invariant).
//
// KEY CONVENTION: `assistant.availability.<case>`, matching the project's dotted
// convention (`separation.unavailable.<case>`). PlayerCore ships NO String
// Catalog, so every key here MUST also exist in BOTH shell catalogs
// (`macOS/Sources/Localizable.xcstrings`, `iOS/Sources/Localizable.xcstrings`) or
// it renders English in every locale. Those keys were synced in the same commit
// as this file — deliberately NOT repeating the pre-existing `separation.*` gap
// (those keys live only in the macOS catalog).
//
// NAMING: the plan calls the top-level AI switch the "master toggle"; the case and
// key here are ``intelligenceDisabled`` because SwiftLint's `inclusive_language`
// rule rejects the word "master" in a DECLARATION under `--strict`. This is the
// same rename that produced ``AISettingsProviding/intelligenceEnabled``; prose and
// accessibility identifiers may still say master, a declaration may not.
import Foundation

/// Localized copy for ``AssistantUnavailableReason``.
public enum AssistantAvailabilityStrings {
    // MARK: Reasons mirrored from Apple's SystemLanguageModel

    public static let unavailableDeviceNotEligible = LocalizedStringResource(
        "assistant.availability.deviceNotEligible",
        defaultValue: "This Mac or device doesn't support Apple Intelligence.",
        comment: "Shown when the hardware cannot run the on-device language model at all"
    )
    public static let unavailableAppleIntelligenceNotEnabled = LocalizedStringResource(
        "assistant.availability.appleIntelligenceNotEnabled",
        defaultValue: "Turn on Apple Intelligence in System Settings to use this.",
        comment: "Shown when the device is capable but the user has not enabled Apple Intelligence"
    )
    public static let unavailableModelNotReady = LocalizedStringResource(
        "assistant.availability.modelNotReady",
        defaultValue: "The on-device model isn't ready yet. Try again shortly.",
        comment: "Shown while the system is still downloading or preparing the on-device language model"
    )

    // MARK: App-specific reasons (no Apple counterpart)

    public static let unavailableOSTooOld = LocalizedStringResource(
        "assistant.availability.osTooOld",
        defaultValue: "This feature needs a newer version of the operating system.",
        comment: "Shown when the running OS predates macOS 26 / iOS 26, so the on-device model cannot be reached at all"
    )
    public static let unavailableRetired = LocalizedStringResource(
        "assistant.availability.retired",
        defaultValue: "Apple Intelligence is being retired. Choose an AI provider in Settings › Intelligence.",
        comment: "Shown when no AI provider is selected now that the Apple Intelligence tier has been retired"
    )
    public static let unavailableIntelligenceDisabled = LocalizedStringResource(
        "assistant.availability.intelligenceDisabled",
        defaultValue: "Intelligence features are turned off in Settings.",
        comment: "Shown when the user's own Intelligence master toggle is off, whatever the system reports"
    )
}
