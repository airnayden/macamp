// IntelligenceConsentSheet — the last screen before anything leaves this Mac.
//
// ── WHY IT IS NESTED INSIDE THE SETUP SHEET ────────────────────────────────────
//
// This is presented FROM ``IntelligenceConnectorConfigSheet``, not from the
// provider section. The two sheets are one decision: declining here must leave the
// setup sheet standing with the draft intact, so the listener can change the
// address or simply Cancel. Presenting it as a sibling of the setup sheet would
// race the outer dismiss and drop the draft on a decline.
//
// ── IT DISCLOSES; IT DOES NOT DECIDE ───────────────────────────────────────────
//
// Accepting calls back into ``IntelligenceConnectorConfigModel``, whose ``save()``
// re-checks consent for itself. So the refusal is enforced at the single commit
// point rather than by this view remembering to ask — a second Save path added
// later inherits the gate instead of bypassing it.
//
// Every number on screen is forwarded from ``ConnectorPayloadBudget`` through
// ``IntelligenceConsentDisclosure``; the provider's name is a BRAND and arrives as
// an interpolation, never as a `Text(verbatim:)` fragment glued to a sentence.
import DesignSystem
import SwiftUI

/// The payload disclosure a non-local provider must clear before its first save.
struct IntelligenceConsentSheet: View {
    let disclosure: IntelligenceConsentDisclosure
    /// Runs on acceptance. The presenter records consent and commits; this view
    /// never writes to a store itself.
    let onAccept: @MainActor () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.large) {
            header
            payload
            notes
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 460)
        .background(tokens.colors.canvas.resolve(scheme))
    }
}

// MARK: - Header

private extension IntelligenceConsentSheet {
    /// `intelligence.connectorConsent.<id>.<element>` — built from the connector id,
    /// so two providers' sheets never collide in the accessibility hierarchy.
    func identifier(_ element: String) -> String {
        "intelligence.connectorConsent.\(disclosure.id).\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Image(systemName: "network")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityHidden(true)
                Text(PreferencesStrings.connectorConsentTitle)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier(identifier("sheet"))
            }
            Text(PreferencesStrings.connectorConsentLead(provider: disclosure.displayName))
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Disclosure

private extension IntelligenceConsentSheet {
    /// The three items, in the order the request itself carries them.
    var payload: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(PreferencesStrings.connectorConsentPayloadHeading)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            payloadRow(PreferencesStrings.connectorConsentRequestItem(characters: disclosure.requestCharacters))
            payloadRow(PreferencesStrings.connectorConsentGenresItem(count: disclosure.genres))
            payloadRow(PreferencesStrings.connectorConsentArtistsItem(count: disclosure.artists))
        }
        .padding(tokens.spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                .fill(tokens.colors.surface.resolve(scheme))
        )
        .accessibilityIdentifier(identifier("payload"))
    }

    func payloadRow(_ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
            Image(systemName: "arrow.up.right")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityHidden(true)
            Text(text)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            PreferenceCaption(text: PreferencesStrings.connectorConsentExclusions)
            PreferenceCaption(text: PreferencesStrings.connectorConsentDefault)
            PreferenceCaption(text: PreferencesStrings.connectorConsentReversible)
        }
    }
}

// MARK: - Actions

private extension IntelligenceConsentSheet {
    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            cancelButton
            acceptButton
        }
    }

    /// Declining writes nothing anywhere — not even the consent record — and leaves
    /// the setup sheet standing.
    var cancelButton: some View {
        Button(role: .cancel) { dismiss() } label: {
            Text(PreferencesStrings.connectorConsentCancel)
        }
        .keyboardShortcut(.cancelAction)
        .help(PreferencesStrings.connectorConsentCancelHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("cancelButton"))
    }

    var acceptButton: some View {
        Button { onAccept() } label: {
            Text(PreferencesStrings.connectorConsentAccept)
        }
        .keyboardShortcut(.defaultAction)
        .help(PreferencesStrings.connectorConsentAcceptHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("acceptButton"))
    }
}

#Preview {
    IntelligenceConsentSheet(
        disclosure: IntelligenceConsentDisclosure(id: "anthropic", displayName: "Anthropic Claude")
    ) {}
        .designTokens(.standard)
}
