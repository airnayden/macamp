// IntelligenceConnectorConfigSheet — where a provider's address or key is entered.
//
// ONE sheet for both credential kinds, because they differ in exactly two places:
// which field is shown, and what the check button is called. Splitting it into an
// Ollama sheet and an API-key sheet would duplicate the header, the status row, the
// three-button footer and the whole commit path to express that difference.
//
// ── THE FIELDS BIND TO THE MODEL'S DRAFT, NEVER TO A STORE ─────────────────────
//
// `$model.draft` is a property nothing observes. Binding a field at
// `settings.ollamaHost` instead would write through `didSet` on every keystroke and
// rebuild the entire assistant graph each time — see
// ``IntelligenceConnectorConfigModel``. Save is the only path from here to
// `AppSettings` or the Keychain, and Cancel simply drops the model.
//
// ── THE CONSENT SHEET IS NESTED HERE, NOT PRESENTED BESIDE THIS ONE ────────────
//
// A provider that would send anything over a network discloses its payload before
// its FIRST save. That sheet is presented from this view, so declining leaves this
// one standing with the draft intact; a sibling presenter in the provider section
// would race this sheet's own dismiss and drop the draft on a decline.
//
// Save is still the only commit path either way: ``IntelligenceConnectorConfigModel``
// `save()` re-checks consent itself, so this view choosing not to ask would refuse
// the write rather than perform it silently.
//
// ── THE STATUS LINE REUSES THE PROVIDER SECTION'S VOCABULARY ───────────────────
//
// A finished check is a `ConnectorStatus`, rendered through
// `PreferencesStrings.connectorStatusMessage(_:)` — the SAME mapping the status row
// two lines up the pane uses. So "this key was rejected" is worded identically in
// both places, and a new status case is one edit, not two.
//
// Provider names and the stock server address are BRANDS and machine addresses:
// rendered `Text(verbatim:)`. Every word the app itself says comes from
// `PreferencesStrings`.
import AIConnectorKit
import DesignSystem
import SwiftUI

/// The modal that configures one connector, committing on Save and on nothing else.
struct IntelligenceConnectorConfigSheet: View {
    /// Run after a commit so the pane re-probes with the credential just saved —
    /// the Keychain is read at call time, so no relaunch and no rebuild is needed.
    let onCommit: @MainActor () async -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var model: IntelligenceConnectorConfigModel
    @State private var isCommitting = false
    @State private var consenting: IntelligenceConsentDisclosure?
    @FocusState private var fieldFocused: Bool

    /// `@MainActor` because ``IntelligenceConnectorConfigModel`` is: SwiftUI forms
    /// this view inside `body`, and a non-`@Sendable` closure there carries the
    /// main actor with it, so the seeding is safe and the annotation is what says so.
    @MainActor
    init(
        configuration: IntelligenceConnectorConfiguration,
        settings: AppSettings,
        onCommit: @escaping @MainActor () async -> Void
    ) {
        self.onCommit = onCommit
        _model = State(initialValue: .live(configuration: configuration, settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.large) {
            header
            credentialField
            checkRow
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 460)
        .background(tokens.colors.canvas.resolve(scheme))
        .task {
            await model.prepare()
            fieldFocused = true
        }
        .sheet(item: $consenting, content: consentSheet)
    }
}

// MARK: - Header

private extension IntelligenceConnectorConfigSheet {
    var configuration: IntelligenceConnectorConfiguration {
        model.configuration
    }

    /// `intelligence.connectorConfig.<id>.<element>` — the identifier shape todo 15
    /// publishes, built from the connector id so two providers never collide.
    func identifier(_ element: String) -> String {
        "intelligence.connectorConfig.\(configuration.id).\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(verbatim: configuration.displayName)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier(identifier("sheet"))
            PreferenceCaption(text: PreferencesStrings.connectorConfigSubtitle)
        }
    }
}

// MARK: - Credential field

private extension IntelligenceConnectorConfigSheet {
    @ViewBuilder
    var credentialField: some View {
        switch configuration.credential {
        case .host: hostField
        case .apiKey: keyField
        }
    }

    /// The placeholder is the connector's OWN default address — data, not copy, so
    /// it is verbatim and always matches what an empty field actually resolves to.
    var hostField: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            TextField(
                text: $model.draft,
                prompt: Text(verbatim: OllamaConnector.defaultHost.absoluteString)
            ) {
                Text(PreferencesStrings.connectorConfigHostLabel)
            }
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .accessibilityIdentifier(identifier("hostField"))
            PreferenceCaption(text: PreferencesStrings.connectorConfigHostCaption)
            if model.supportsOptionalAPIKey {
                optionalKeyField
            }
        }
    }

    /// The OPTIONAL bearer beneath the address.
    ///
    /// Empty on appear, always — the stored key is never read back into a
    /// `SecureField`, and here an empty field additionally means "leave whatever is
    /// saved alone" rather than "clear it". Removing a key is the Remove button.
    var optionalKeyField: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            SecureField(
                text: $model.secretDraft,
                prompt: Text(PreferencesStrings.connectorConfigOptionalKeyPrompt)
            ) {
                Text(PreferencesStrings.connectorConfigOptionalKeyLabel)
            }
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(identifier("optionalKeyField"))
            if model.hasStoredSecret {
                PreferenceCaption(text: PreferencesStrings.connectorConfigKeyStored)
            }
            PreferenceCaption(text: PreferencesStrings.connectorConfigOptionalKeyCaption)
        }
        .padding(.top, tokens.spacing.xSmall)
    }

    /// Empty on appear, ALWAYS: the stored key is never read back into a
    /// `SecureField`. The caption is what tells the listener one is already saved.
    var keyField: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            SecureField(
                text: $model.draft,
                prompt: Text(PreferencesStrings.connectorConfigKeyPrompt)
            ) {
                Text(PreferencesStrings.connectorConfigKeyLabel)
            }
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .accessibilityIdentifier(identifier("keyField"))
            if model.hasStoredSecret {
                PreferenceCaption(text: PreferencesStrings.connectorConfigKeyStored)
            }
            PreferenceCaption(text: PreferencesStrings.connectorConfigKeyCaption)
        }
    }
}

// MARK: - Check

private extension IntelligenceConnectorConfigSheet {
    var checkRow: some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                if model.validation == .checking {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(checkMessage)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(checkTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier("status"))
                Spacer(minLength: tokens.spacing.xSmall)
                checkButton
            }
        } label: {
            Text(PreferencesStrings.connectorConfigCheckLabel)
        }
    }

    var checkButton: some View {
        Button {
            Task { await model.validate() }
        } label: {
            Text(isHostCredential ? PreferencesStrings.connectorConfigTest : PreferencesStrings.connectorConfigValidate)
        }
        .disabled(model.validation == .checking || !model.canSave)
        .help(isHostCredential ? PreferencesStrings.connectorConfigTestHelp : PreferencesStrings
            .connectorConfigValidateHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier(isHostCredential ? "testButton" : "validateButton"))
    }

    var isHostCredential: Bool {
        configuration.credential == .host
    }

    var checkMessage: LocalizedStringResource {
        switch model.validation {
        case .idle: PreferencesStrings.connectorConfigCheckIdle
        case .checking: PreferencesStrings.intelligenceConnectorChecking
        case let .finished(status): PreferencesStrings.connectorStatusMessage(status)
        }
    }

    var checkTint: Color {
        guard case let .finished(status) = model.validation, status.isReady else {
            return tokens.colors.textSecondary.resolve(scheme)
        }
        return tokens.colors.success.resolve(scheme)
    }
}

// MARK: - Actions

private extension IntelligenceConnectorConfigSheet {
    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            removeButton
            Spacer()
            cancelButton
            saveButton
        }
        .disabled(isCommitting)
    }

    var removeButton: some View {
        Button(role: .destructive) {
            commit { await model.remove() }
        } label: {
            Text(PreferencesStrings.connectorConfigRemove)
        }
        .disabled(!model.canRemove)
        .help(isHostCredential
            ? PreferencesStrings.connectorConfigRemoveHostHelp
            : PreferencesStrings.connectorConfigRemoveKeyHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("removeButton"))
    }

    var cancelButton: some View {
        Button(role: .cancel) { dismiss() } label: {
            Text(PreferencesStrings.connectorConfigCancel)
        }
        .keyboardShortcut(.cancelAction)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("cancelButton"))
    }

    /// Save either commits or asks first — it never does both, and it never
    /// commits behind the disclosure.
    var saveButton: some View {
        Button {
            if model.requiresConsent {
                consenting = model.disclosure
            } else {
                commit { await model.save() }
            }
        } label: {
            Text(PreferencesStrings.connectorConfigSave)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("saveButton"))
    }

    /// Accepting records the consent and commits in one step, so the single
    /// confirmation does what its label promises. Declining clears nothing but the
    /// nested sheet: no consent, no write, and this sheet is still standing.
    func consentSheet(_ disclosure: IntelligenceConsentDisclosure) -> some View {
        IntelligenceConsentSheet(disclosure: disclosure) {
            consenting = nil
            commit {
                model.grantConsent()
                await model.save()
            }
        }
    }

    /// Runs one commit, refreshes the pane, then closes. `isCommitting` disables
    /// the footer meanwhile so a second tap cannot start a competing write.
    func commit(_ work: @escaping @MainActor () async -> Void) {
        guard !isCommitting else { return }
        isCommitting = true
        Task {
            await work()
            await onCommit()
            isCommitting = false
            dismiss()
        }
    }
}

#Preview {
    IntelligenceConnectorConfigSheet(
        configuration: IntelligenceConnectorConfiguration(
            id: AnthropicConnector.connectorID,
            displayName: "Anthropic Claude",
            credential: .apiKey
        ),
        settings: .preview
    ) {}
        .designTokens(.standard)
}
