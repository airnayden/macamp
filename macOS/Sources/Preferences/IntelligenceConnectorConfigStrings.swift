// IntelligenceConnectorConfigStrings — every word the connector configuration sheet says.
//
// A THIRD strings file rather than a bigger second one: `PreferencesStrings` was
// already split into `IntelligencePreferencesStrings` (221 lines) and
// `IntelligenceConnectorStrings` (255), and `file_length` is capped at 400 under
// `swiftlint --strict`. Declared as an extension, so every call site still reads
// `PreferencesStrings.<name>` and the split stays invisible to the views.
//
// ── WHAT IS *NOT* HERE ─────────────────────────────────────────────────────────
//
// The sheet's status line is NOT its own vocabulary: a validation attempt answers
// with a `ConnectorStatus`, and that is rendered through the SAME
// `PreferencesStrings.connectorStatusMessage(_:)` the provider section's status row
// uses. One taxonomy, one mapping — a "Validate" button that invented its own way
// to say "the key was rejected" would drift from the row two lines above it.
//
// Provider names ("Ollama", "OpenAI") and the stock server address are BRANDS and
// machine addresses: the sheet renders those `Text(verbatim:)`, never from here.
import Foundation

extension PreferencesStrings {
    // MARK: Entry point (provider section)

    static let intelligenceConnectorConfigure = LocalizedStringResource(
        "app.preferences.intelligence.provider.configure",
        defaultValue: "Set Up…",
        comment: "Button beside the provider picker that opens the selected provider's setup sheet"
    )
    static let intelligenceConnectorConfigureHelp = LocalizedStringResource(
        "app.preferences.intelligence.provider.configure.help",
        defaultValue: "Enter this provider's address or key.",
        comment: "Tooltip of the button opening the selected provider's setup sheet"
    )

    // MARK: Sheet chrome

    static let connectorConfigSubtitle = LocalizedStringResource(
        "app.preferences.intelligence.config.subtitle",
        defaultValue: "Tell MacAMP how to reach this provider. Nothing is saved until you choose Save.",
        comment: "Subtitle of the provider setup sheet, stating that edits are not applied while typing"
    )
    static let connectorConfigSave = LocalizedStringResource(
        "app.preferences.intelligence.config.save",
        defaultValue: "Save",
        comment: "Button committing the provider setup sheet"
    )
    static let connectorConfigCancel = LocalizedStringResource(
        "app.preferences.intelligence.config.cancel",
        defaultValue: "Cancel",
        comment: "Button dismissing the provider setup sheet without saving"
    )
    static let connectorConfigRemove = LocalizedStringResource(
        "app.preferences.intelligence.config.remove",
        defaultValue: "Remove",
        comment: "Button deleting this provider's saved credential and stopping its use"
    )

    // MARK: Server address (Ollama)

    static let connectorConfigHostLabel = LocalizedStringResource(
        "app.preferences.intelligence.config.host",
        defaultValue: "Server address",
        comment: "Label of the field holding a local provider's base address"
    )
    static let connectorConfigHostCaption = LocalizedStringResource(
        "app.preferences.intelligence.config.host.caption",
        defaultValue: "Leave this empty to use the provider's standard address.",
        comment: "Caption under the server address field explaining the empty value"
    )
    static let connectorConfigTest = LocalizedStringResource(
        "app.preferences.intelligence.config.test",
        defaultValue: "Test Connection",
        comment: "Button contacting the typed server address to check it answers"
    )
    static let connectorConfigTestHelp = LocalizedStringResource(
        "app.preferences.intelligence.config.test.help",
        defaultValue: "Contact this address now and list the models it offers. Nothing is saved.",
        comment: "Tooltip of the test-connection button"
    )
    static let connectorConfigRemoveHostHelp = LocalizedStringResource(
        "app.preferences.intelligence.config.remove.host.help",
        defaultValue: "Forget this address and go back to Apple Intelligence.",
        comment: "Tooltip of the remove button for a provider configured by address"
    )

    // MARK: Optional API key (Ollama Cloud)

    static let connectorConfigOptionalKeyLabel = LocalizedStringResource(
        "app.preferences.intelligence.config.optionalKey",
        defaultValue: "API key (optional)",
        comment: "Label of the secure field holding the optional key a hosted Ollama server needs"
    )
    static let connectorConfigOptionalKeyPrompt = LocalizedStringResource(
        "app.preferences.intelligence.config.optionalKey.prompt",
        defaultValue: "Only needed for a hosted server",
        comment: "Placeholder of the optional API key field beneath the server address"
    )
    static let connectorConfigOptionalKeyCaption = LocalizedStringResource(
        "app.preferences.intelligence.config.optionalKey.caption",
        defaultValue: "Leave empty for a server you run yourself. Ollama Cloud needs a key; it is kept in your login keychain.",
        comment: "Caption under the optional API key field explaining when it is needed and where it is stored"
    )

    // MARK: API key (Anthropic, OpenAI)

    static let connectorConfigKeyLabel = LocalizedStringResource(
        "app.preferences.intelligence.config.key",
        defaultValue: "API key",
        comment: "Label of the secure field holding a provider's API key"
    )
    static let connectorConfigKeyPrompt = LocalizedStringResource(
        "app.preferences.intelligence.config.key.prompt",
        defaultValue: "Paste your API key",
        comment: "Placeholder of the secure field holding a provider's API key"
    )
    static let connectorConfigKeyCaption = LocalizedStringResource(
        "app.preferences.intelligence.config.key.caption",
        defaultValue: "Kept in your login keychain — never in MacAMP's preferences, and never written to a log.",
        comment: "Caption under the API key field stating where the key is stored"
    )
    /// Shown when a key IS stored. The stored key itself is never read back into
    /// the field — see ``IntelligenceConnectorConfigModel/prepare()``.
    static let connectorConfigKeyStored = LocalizedStringResource(
        "app.preferences.intelligence.config.key.stored",
        defaultValue: "A key is already saved. Type a new one to replace it.",
        comment: "Caption shown when a key is already stored, so the empty field is not mistaken for none"
    )
    static let connectorConfigValidate = LocalizedStringResource(
        "app.preferences.intelligence.config.validate",
        defaultValue: "Validate",
        comment: "Button checking the typed API key against the provider"
    )
    static let connectorConfigValidateHelp = LocalizedStringResource(
        "app.preferences.intelligence.config.validate.help",
        defaultValue: "Check this key now by listing the models it can reach. Nothing is saved.",
        comment: "Tooltip of the validate button"
    )
    static let connectorConfigRemoveKeyHelp = LocalizedStringResource(
        "app.preferences.intelligence.config.remove.key.help",
        defaultValue: "Delete the saved key from your keychain and go back to Apple Intelligence.",
        comment: "Tooltip of the remove button for a provider configured by API key"
    )

    // MARK: Validation row

    static let connectorConfigCheckLabel = LocalizedStringResource(
        "app.preferences.intelligence.config.check",
        defaultValue: "Check",
        comment: "Label of the row reporting the result of a test or validate attempt"
    )
    static let connectorConfigCheckIdle = LocalizedStringResource(
        "app.preferences.intelligence.config.check.idle",
        defaultValue: "Not checked yet.",
        comment: "Shown before any test or validate attempt has run"
    )
}
