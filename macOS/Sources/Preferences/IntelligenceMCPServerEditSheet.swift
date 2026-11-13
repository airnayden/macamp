// IntelligenceMCPServerEditSheet — where a server is described, and nowhere else.
//
// ── THE FIELDS BIND TO A DRAFT, NEVER TO THE STORE ───────────────────────────
//
// Same rule ``IntelligenceConnectorConfigSheet`` follows: `$draft.…` is a value
// nothing observes, so a keystroke costs a redraw of this sheet and not a write to
// `UserDefaults` plus a Keychain round trip. Save is the only path out of here, and
// Cancel simply drops the draft.
//
// ── NAMES AND VALUES ARE ENTERED IN DIFFERENT FIELDS ON PURPOSE ──────────────
//
// ``MCPServerDescriptor`` persists credential NAMES; the VALUES go to the Keychain
// through `MCPServerConfigStore.save(_:secretValues:)`, which settles both stores
// together. The layout mirrors that split — a plain field for the names, secure
// fields underneath for their values — because a single "Authorization: Bearer …"
// field is one paste away from putting a token in the plist that
// `MCPServerConfigPersistenceTests` proves must never hold one.
//
// ── SAVING DOES NOT ENABLE ───────────────────────────────────────────────────
//
// A saved server is off and unconsented. Nothing here can grant either; that is
// ``IntelligenceMCPConsentSheet``'s job, reached from the row's switch.
import AIConnectorMCP
import DesignSystem
import SwiftUI

/// The modal that describes one MCP server, committing on Save and on nothing else.
struct IntelligenceMCPServerEditSheet: View {
    let request: MCPServerEditRequest
    /// Runs on Save with the described server and any credential values typed.
    let onCommit: @MainActor (MCPServerDescriptor, [String: String]) async -> Void

    @State private var draft: MCPServerDraft
    @State private var isCommitting = false
    @FocusState private var isNameFocused: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(
        request: MCPServerEditRequest,
        onCommit: @escaping @MainActor (MCPServerDescriptor, [String: String]) async -> Void
    ) {
        self.request = request
        self.onCommit = onCommit
        _draft = State(initialValue: MCPServerDraft(existing: request.existing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            header
            nameField
            transportPicker
            endpointFields
            secretFields
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 480)
        .background(tokens.colors.canvas.resolve(scheme))
        .onAppear { isNameFocused = true }
    }
}

// MARK: - Header

private extension IntelligenceMCPServerEditSheet {
    func identifier(_ element: String) -> String {
        "intelligence.mcp.edit.\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(request.existing == nil
                ? PreferencesStrings.mcpEditAddTitle
                : PreferencesStrings.mcpEditChangeTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier(identifier("sheet"))
            PreferenceCaption(text: PreferencesStrings.mcpEditSubtitle)
        }
    }

    var nameField: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            TextField(text: $draft.name, prompt: Text(PreferencesStrings.mcpFieldNamePrompt)) {
                Text(PreferencesStrings.mcpFieldName)
            }
            .textFieldStyle(.roundedBorder)
            .focused($isNameFocused)
            .accessibilityIdentifier(identifier("nameField"))
        }
    }

    var transportPicker: some View {
        Picker(selection: $draft.transport) {
            Text(PreferencesStrings.mcpTransportStdio).tag(MCPServerDraft.Transport.stdio)
            Text(PreferencesStrings.mcpTransportHTTP).tag(MCPServerDraft.Transport.http)
        } label: {
            Text(PreferencesStrings.mcpFieldTransport)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier("transportPicker"))
    }
}

// MARK: - Endpoint

private extension IntelligenceMCPServerEditSheet {
    @ViewBuilder
    var endpointFields: some View {
        switch draft.transport {
        case .stdio: commandFields
        case .http: addressFields
        }
    }

    var commandFields: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            field(
                text: $draft.command,
                label: PreferencesStrings.mcpFieldCommand,
                prompt: Text(verbatim: "npx"),
                caption: PreferencesStrings.mcpFieldCommandCaption,
                element: "commandField"
            )
            multilineField(
                text: $draft.argumentsText,
                label: PreferencesStrings.mcpFieldArguments,
                caption: PreferencesStrings.mcpFieldArgumentsCaption,
                element: "argumentsField"
            )
            multilineField(
                text: $draft.environmentKeysText,
                label: PreferencesStrings.mcpFieldEnvironmentKeys,
                caption: PreferencesStrings.mcpFieldEnvironmentKeysCaption,
                element: "environmentKeysField"
            )
        }
    }

    var addressFields: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            field(
                text: $draft.address,
                label: PreferencesStrings.mcpFieldURL,
                prompt: Text(verbatim: "https://example.com/mcp"),
                caption: PreferencesStrings.mcpFieldURLCaption,
                element: "addressField"
            )
            if !draft.address.isEmpty, draft.parsedAddress == nil {
                Text(PreferencesStrings.mcpFieldURLInvalid)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityIdentifier(identifier("addressInvalid"))
            }
            multilineField(
                text: $draft.headerKeysText,
                label: PreferencesStrings.mcpFieldHeaderKeys,
                caption: PreferencesStrings.mcpFieldHeaderKeysCaption,
                element: "headerKeysField"
            )
        }
    }

    func field(
        text: Binding<String>,
        label: LocalizedStringResource,
        prompt: Text,
        caption: LocalizedStringResource,
        element: String
    ) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            TextField(text: text, prompt: prompt) { Text(label) }
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier(element))
            PreferenceCaption(text: caption)
        }
    }

    func multilineField(
        text: Binding<String>,
        label: LocalizedStringResource,
        caption: LocalizedStringResource,
        element: String
    ) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            TextField(text: text, axis: .vertical) { Text(label) }
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 4)
                .accessibilityIdentifier(identifier(element))
            PreferenceCaption(text: caption)
        }
    }
}

// MARK: - Credentials

private extension IntelligenceMCPServerEditSheet {
    /// One secure field per declared name. Blank means "leave what is saved alone",
    /// which is why an empty value is dropped rather than written through.
    @ViewBuilder
    var secretFields: some View {
        if draft.secretNames.isEmpty == false {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Text(PreferencesStrings.mcpFieldSecretsHeading)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                ForEach(draft.secretNames, id: \.self) { name in
                    SecureField(text: secretBinding(for: name)) {
                        Text(verbatim: name)
                    }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(verbatim: name))
                    .accessibilityIdentifier(identifier("secretField.\(name)"))
                }
                PreferenceCaption(text: PreferencesStrings.mcpFieldSecretsCaption)
            }
        }
    }

    func secretBinding(for name: String) -> Binding<String> {
        Binding(
            get: { draft.secretValues[name] ?? "" },
            set: { draft.secretValues[name] = $0 }
        )
    }
}

// MARK: - Actions

private extension IntelligenceMCPServerEditSheet {
    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            Button(role: .cancel) { dismiss() } label: {
                Text(PreferencesStrings.mcpEditCancel)
            }
            .keyboardShortcut(.cancelAction)
            .pointingHandCursor()
            .accessibilityIdentifier(identifier("cancelButton"))
            saveButton
        }
        .disabled(isCommitting)
    }

    var saveButton: some View {
        Button { commit() } label: {
            Text(PreferencesStrings.mcpEditSave)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft.descriptor(id: request.id, existing: request.existing) == nil)
        .help(PreferencesStrings.mcpEditSaveHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("saveButton"))
    }

    func commit() {
        guard !isCommitting,
              let descriptor = draft.descriptor(id: request.id, existing: request.existing)
        else { return }
        isCommitting = true
        Task {
            await onCommit(descriptor, draft.enteredSecretValues)
            isCommitting = false
            dismiss()
        }
    }
}

#Preview {
    IntelligenceMCPServerEditSheet(request: MCPServerEditRequest(id: UUID(), existing: nil)) { _, _ in }
        .designTokens(.standard)
}
