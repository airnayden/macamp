// IntelligenceProviderSection — choose who answers, and on which model.
//
// Two pickers over one probe. The connector picker writes
// `AppSettings.selectedConnectorID`; `AppEnvironment` reads that inside
// `withObservationTracking` and REBUILDS the assistant graph, so selecting a
// provider takes effect with no relaunch and — critically — with no `.onChange`
// here. This file contains none: the pane's contract is that the composition
// observes and the view only binds.
//
// The async work rides `.task(id: settings.selectedConnectorID)` instead. That
// starts on appear, restarts on every new selection, and cancels the outgoing
// probe — the three behaviours an `.onChange` pair would have to reproduce, and
// the reason the model needs no observation of its own.
//
// Provider and model names are BRANDS and provider-assigned identifiers ("Ollama",
// "llama3.2:latest"), so they are rendered `Text(verbatim:)`. Everything the app
// itself says goes through `PreferencesStrings`, including every one of the five
// `ConnectorStatus` cases — a machine token never reaches a label.
import AIConnectorBridge
import AIConnectorKit
import DesignSystem
import Services
import SwiftUI

/// The provider picker, its model picker, and the selected connector's live state.
struct IntelligenceProviderSection: View {
    @Bindable var settings: AppSettings
    let provider: IntelligenceProviderModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// The connector whose setup sheet is up, driving `.sheet(item:)` directly —
    /// so the identity that decides which sheet is presented is the same one its
    /// accessibility identifiers and Keychain namespace are built from.
    @State private var configuring: IntelligenceConnectorConfiguration?

    #if MACAMP_EXTERNAL_OAUTH
        /// Whether a subscription login is up. It needs a presenter of its own
        /// because `configuring` is `nil` for a subscription connector by design —
        /// signing in is a different act from saving a credential, not the same
        /// sheet with a different field.
        ///
        /// One flag PER PROVIDER rather than one shared optional: each sheet is
        /// attached to its own `Button`, and `.sheet(isPresented:)` on a view that
        /// only exists for the selected connector cannot collide with the other.
        @State private var signingInToClaudeSubscription = false
        @State private var signingInToChatGPTSubscription = false
    #endif

    var body: some View {
        Section {
            sectionTitle
            connectorPicker
            PreferenceCaption(
                text: AppleIntelligenceRetirement.isRetired
                    ? PreferencesStrings.intelligenceProviderCaptionRetired
                    : PreferencesStrings.intelligenceProviderCaption
            )
            if AppleIntelligenceRetirement.isRetired {
                PreferenceCaption(text: PreferencesStrings.intelligenceAppleIntelligenceRetired)
            }
            if let selection = provider.selection {
                statusRow(selection)
                modelPicker
                modelNotice
            }
        }
        .disabled(!settings.intelligenceEnabled)
        .task(id: settings.selectedConnectorID) {
            await provider.reload(connectorID: settings.selectedConnectorID, registry: liveRegistry)
        }
        .sheet(item: $configuring, content: configSheet)
    }
}

// MARK: - Registry

private extension IntelligenceProviderSection {
    /// The registry the ladder actually routes through when the graph exists, so
    /// the picker cannot list a connector the assistant would not use. With the
    /// master switch off there is no graph, so an equivalent one is built for
    /// display — it reads no secret and performs no request until probed.
    var liveRegistry: ConnectorRegistry {
        environment.intelligence?.connectors ?? AppEnvironment.makeConnectorRegistry(settings: settings)
    }

    var sectionTitle: some View {
        Text(PreferencesStrings.intelligenceProviderSection)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
    }
}

// MARK: - Pickers

private extension IntelligenceProviderSection {
    var connectorPicker: some View {
        Picker(selection: $settings.selectedConnectorID) {
            // Apple Intelligence is retired: `nil` now means "no provider", not the
            // on-device model, so the entry is relabelled rather than removed.
            Text(
                AppleIntelligenceRetirement.isRetired
                    ? PreferencesStrings.intelligenceProviderNone
                    : PreferencesStrings.intelligenceProviderDefault
            )
            .tag(String?.none)
            ForEach(provider.registry.descriptors, id: \.id) { descriptor in
                Text(verbatim: descriptor.displayName).tag(String?.some(descriptor.id))
            }
        } label: {
            Text(PreferencesStrings.intelligenceProviderLabel)
        }
        .accessibilityIdentifier("intelligence.connectorPicker")
    }

    var modelPicker: some View {
        Picker(selection: modelBinding) {
            Text(PreferencesStrings.intelligenceModelAutomatic).tag(String?.none)
            ForEach(modelOptions, id: \.id) { model in
                Text(verbatim: model.displayName).tag(String?.some(model.id))
            }
        } label: {
            Text(PreferencesStrings.intelligenceModelLabel)
        }
        .accessibilityIdentifier("intelligence.modelPicker")
        .disabled(modelOptions.isEmpty)
    }

    /// Writes through to the PER-CONNECTOR slot: model namespaces do not overlap,
    /// so switching provider and back must never hand one a name it never had.
    var modelBinding: Binding<String?> {
        Binding(
            get: { provider.selection.flatMap { settings.selectedModel(for: $0.id) } },
            set: { chosen in
                guard let selection = provider.selection else { return }
                settings.setSelectedModel(chosen, for: selection.id)
            }
        )
    }

    /// What the last probe enumerated, plus the stored choice when the provider no
    /// longer lists it — dropping that row would silently show "Automatic" for a
    /// model the assistant is still being asked to use.
    var modelOptions: [ModelInfo] {
        let listed = provider.reportedModels ?? []
        guard let selection = provider.selection,
              let chosen = settings.selectedModel(for: selection.id),
              !listed.contains(where: { $0.id == chosen })
        else { return listed }
        return [ModelInfo(id: chosen)] + listed
    }

    /// `nil` and `[]` are different answers and say different things: nothing has
    /// been listed yet, versus the provider genuinely offers none.
    @ViewBuilder
    var modelNotice: some View {
        if provider.reportedModels == nil {
            PreferenceCaption(text: PreferencesStrings.intelligenceModelsUnknown)
        } else if provider.reportedModels?.isEmpty == true {
            PreferenceCaption(text: PreferencesStrings.intelligenceModelsEmpty)
        }
    }
}

// MARK: - Status

private extension IntelligenceProviderSection {
    func statusRow(_ selection: IntelligenceProviderModel.Selection) -> some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                statusGlyph(selection)
                Text(statusMessage(selection))
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(statusTint(selection))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("intelligence.connectorStatus.\(selection.id)")
                Spacer(minLength: tokens.spacing.xSmall)
                configureButton(selection)
                refreshButton(selection)
            }
        } label: {
            Text(PreferencesStrings.intelligenceConnectorStatusLabel)
        }
    }

    @ViewBuilder
    func statusGlyph(_ selection: IntelligenceProviderModel.Selection) -> some View {
        if selection.isProbing {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        } else {
            Image(systemName: selection.status?.isReady == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(statusTint(selection))
                .accessibilityHidden(true)
        }
    }

    func refreshButton(_ selection: IntelligenceProviderModel.Selection) -> some View {
        Button {
            Task { await provider.reload(connectorID: selection.id, registry: liveRegistry) }
        } label: {
            Label { Text(PreferencesStrings.intelligenceConnectorRefresh) } icon: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(selection.isProbing)
        .help(PreferencesStrings.intelligenceConnectorRefreshHelp)
        .pointingHandCursor()
        .accessibilityIdentifier("intelligence.connectorRefresh")
    }

    func statusMessage(_ selection: IntelligenceProviderModel.Selection) -> LocalizedStringResource {
        guard let status = selection.status else { return PreferencesStrings.intelligenceConnectorChecking }
        return PreferencesStrings.connectorStatusMessage(status)
    }

    func statusTint(_ selection: IntelligenceProviderModel.Selection) -> Color {
        selection.status?.isReady == true
            ? tokens.colors.success.resolve(scheme)
            : tokens.colors.textSecondary.resolve(scheme)
    }
}

// MARK: - Setup sheet

private extension IntelligenceProviderSection {
    /// Absent — not disabled — for a provider with nothing to type: a subscription
    /// connector is configured by signing in, so an inert "Set Up…" beside it would
    /// promise a sheet that does not exist. It gets ``subscriptionSignInButton(_:)``
    /// instead, which opens the login that actually configures it.
    @ViewBuilder
    func configureButton(_ selection: IntelligenceProviderModel.Selection) -> some View {
        if let configuration = configuration(for: selection) {
            Button { configuring = configuration } label: {
                Text(PreferencesStrings.intelligenceConnectorConfigure)
            }
            .help(PreferencesStrings.intelligenceConnectorConfigureHelp)
            .pointingHandCursor()
            .accessibilityIdentifier("intelligence.connectorConfigure")
        } else {
            subscriptionSignInButton(selection)
        }
    }

    func configuration(for selection: IntelligenceProviderModel.Selection) -> IntelligenceConnectorConfiguration? {
        provider.registry.descriptor(id: selection.id)
            .flatMap(IntelligenceConnectorConfiguration.init(descriptor:))
    }

    /// A committed sheet re-probes explicitly rather than relying on
    /// `.task(id: settings.selectedConnectorID)`: saving a key writes the id that is
    /// ALREADY selected, so the task's identity does not change and it never re-runs.
    func configSheet(_ configuration: IntelligenceConnectorConfiguration) -> some View {
        IntelligenceConnectorConfigSheet(configuration: configuration, settings: settings) {
            await provider.reload(connectorID: settings.selectedConnectorID, registry: liveRegistry)
        }
    }
}

// MARK: - Subscription sign-in

private extension IntelligenceProviderSection {
    /// The affordance for a connector configured by logging in rather than by typing.
    ///
    /// Everything it names lives in `macOS/ExternalOAuth/`, so the flag is what lets
    /// this file — which is under `Sources/` — reference that folder at all. The `#if`
    /// sits INSIDE the body rather than around the declaration so the caller's
    /// `if/else` stays one expression however the flag resolves.
    @ViewBuilder
    func subscriptionSignInButton(_ selection: IntelligenceProviderModel.Selection) -> some View {
        #if MACAMP_EXTERNAL_OAUTH
            if selection.id == ExternalOAuthComposition.claudeConnectorID {
                signInButton(isPresented: $signingInToClaudeSubscription) { ClaudeSignInSheet() }
            } else if selection.id == ExternalOAuthComposition.chatGPTConnectorID {
                signInButton(isPresented: $signingInToChatGPTSubscription) { ChatGPTSignInSheet() }
            }
        #endif
    }

    #if MACAMP_EXTERNAL_OAUTH
        /// The shared "Sign In…" affordance. Both subscription providers get the
        /// same button, tooltip and accessibility identifier — only the sheet body
        /// differs, because only the flow differs.
        func signInButton(
            isPresented: Binding<Bool>,
            @ViewBuilder sheet: @escaping () -> some View
        ) -> some View {
            Button { isPresented.wrappedValue = true } label: {
                Text(PreferencesStrings.intelligenceConnectorSignIn)
            }
            .help(PreferencesStrings.intelligenceConnectorSignInHelp)
            .pointingHandCursor()
            .accessibilityIdentifier("intelligence.connectorSignIn")
            .sheet(isPresented: isPresented, content: sheet)
        }
    #endif
}

#Preview {
    Form {
        IntelligenceProviderSection(settings: .preview, provider: IntelligenceProviderModel())
    }
    .formStyle(.grouped)
    .environment(AppEnvironment.preview())
    .designTokens(.standard)
}
