// IntelligenceWebSuggestionsSection — the switch, the disclosure, and the two keys
// that are allowed to be absent.
//
// ── WHY IT SITS BETWEEN EXTERNAL ACCESS AND MCP SERVERS ──────────────────────
//
// The pane is ordered by direction of trust. External access is "which programs may
// talk to MacAMP"; MCP servers are "which programs may MacAMP talk to". This sits
// between them because it is the same question about a service the listener never
// configures: MacAMP talks OUT, but to two fixed, named endpoints rather than to
// something the listener added. Reading it after external access means the
// vocabulary — a grant, a disclosure, a reversible switch — is already familiar;
// reading it before MCP means the general case arrives last.
//
// ── THE VIEW HOLDS NO POLICY ─────────────────────────────────────────────────
//
// Whether the switch may move, whether the disclosure appears, and whether a typed
// key is worth committing are all ``WebSuggestionsSectionModel``'s. This file
// positions and paints. The switch's binding setter is one call into the model, so
// a second control added here later cannot bypass the consent gate.
//
// ── THE KEY FIELDS COMMIT ON A BUTTON, NEVER ON A KEYSTROKE ──────────────────
//
// A `SecureField` bound straight at a `SecretStore` performs a Keychain write per
// character. The draft lives in the model, which nothing observes but this section,
// and reaches the Keychain only from Save (or Return). The same rule
// ``IntelligenceConnectorConfigModel`` documents at length.
import DesignSystem
import SwiftUI

/// Web & music suggestions: the disclosure-gated switch, and the two optional API
/// keys that only raise a rate limit.
struct IntelligenceWebSuggestionsSection: View {
    @Bindable var settings: AppSettings

    @State private var model: WebSuggestionsSectionModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @MainActor
    init(settings: AppSettings) {
        self.settings = settings
        _model = State(initialValue: .live(settings: settings))
    }

    var body: some View {
        Section {
            Text(PreferencesStrings.webSuggestionsSection)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Toggle(isOn: enabledBinding) {
                Text(PreferencesStrings.webSuggestionsToggle)
            }
            .pointingHandCursor()
            .accessibilityIdentifier("intelligence.webSuggestions.toggle")
            PreferenceCaption(text: PreferencesStrings.webSuggestionsCaption)
            PreferenceCaption(text: PreferencesStrings.webSuggestionsCloudOnlyCaption)
            if !settings.intelligenceEnabled {
                PreferenceCaption(text: PreferencesStrings.webSuggestionsNeedsIntelligence)
            }
            keys
        }
        .disabled(!settings.intelligenceEnabled)
        .task { await model.refreshStoredKeys() }
        .sheet(item: $model.consenting) { disclosure in
            IntelligenceWebSuggestionsConsentSheet(
                disclosure: disclosure,
                onAccept: { model.acceptConsent() },
                onDecline: { model.declineConsent() }
            )
        }
    }
}

// MARK: - The switch

private extension IntelligenceWebSuggestionsSection {
    /// Switching ON without the disclosure on file OFFERS it and writes nothing;
    /// the sheet's accept handler is the only thing that flips either record.
    /// Switching OFF is unconditional and immediate.
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.webSuggestionsEnabled },
            set: { model.setEnabled($0) }
        )
    }
}

// MARK: - The two optional keys

private extension IntelligenceWebSuggestionsSection {
    @ViewBuilder
    var keys: some View {
        Text(PreferencesStrings.webSuggestionsKeysHeading)
            .font(tokens.typography.callout.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
        PreferenceCaption(text: PreferencesStrings.webSuggestionsKeysCaption)
        IntelligenceWebSuggestionsKeyRow(
            model: model,
            slot: .search,
            providerName: WebSuggestionsDisclosure.live.searchProviderName
        )
        IntelligenceWebSuggestionsKeyRow(
            model: model,
            slot: .video,
            providerName: WebSuggestionsDisclosure.live.videoProviderName
        )
        if model.didFailToStoreKey {
            PreferenceCaption(text: PreferencesStrings.webSuggestionsKeyFailed)
        }
    }
}

// MARK: - One key

/// One optional credential: the field, what is on file, and the two things that can
/// be done to it.
private struct IntelligenceWebSuggestionsKeyRow: View {
    let model: WebSuggestionsSectionModel
    let slot: WebSuggestionsKeySlot
    /// The provider's own name. A BRAND: never localized, only interpolated.
    let providerName: String

    @Environment(\.designTokens) private var tokens

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                field
                PreferenceCaption(text: status)
                actions
            }
        } label: {
            Text(label)
        }
    }

    private var label: LocalizedStringResource {
        PreferencesStrings.webSuggestionsKeyLabel(slot, provider: providerName)
    }

    /// Never seeded from the Keychain: a stored key stays where it is, and an empty
    /// field means "not entered this time" rather than "delete it".
    private var draft: Binding<String> {
        Binding(
            get: { model.draft(for: slot) },
            set: { model.setDraft($0, for: slot) }
        )
    }

    private var status: LocalizedStringResource {
        model.hasStoredKey(slot)
            ? PreferencesStrings.webSuggestionsKeySaved
            : PreferencesStrings.webSuggestionsKeyAbsent
    }
}

// MARK: - Field and actions

private extension IntelligenceWebSuggestionsKeyRow {
    var field: some View {
        SecureField(text: draft) {
            Text(label)
        }
        .labelsHidden()
        .frame(maxWidth: 280)
        .onSubmit { Task { await model.saveKey(for: slot) } }
        .accessibilityLabel(label)
        .accessibilityIdentifier("intelligence.webSuggestions.keyField.\(slot.rawValue)")
    }

    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            saveButton
            removeButton
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    var saveButton: some View {
        Button {
            Task { await model.saveKey(for: slot) }
        } label: {
            Text(PreferencesStrings.webSuggestionsSaveKey)
        }
        .disabled(!model.canSaveKey(for: slot))
        .help(PreferencesStrings.webSuggestionsSaveKeyHelp)
        .pointingHandCursor()
        .accessibilityIdentifier("intelligence.webSuggestions.saveKey.\(slot.rawValue)")
    }

    var removeButton: some View {
        Button(role: .destructive) {
            Task { await model.removeKey(for: slot) }
        } label: {
            Text(PreferencesStrings.webSuggestionsRemoveKey)
        }
        .disabled(!model.hasStoredKey(slot))
        .help(PreferencesStrings.webSuggestionsRemoveKeyHelp)
        .pointingHandCursor()
        .accessibilityIdentifier("intelligence.webSuggestions.removeKey.\(slot.rawValue)")
    }
}
