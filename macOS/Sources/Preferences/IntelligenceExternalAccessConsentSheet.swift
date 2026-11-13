// IntelligenceExternalAccessConsentSheet — the last screen before the port opens.
//
// Shaped deliberately like the two disclosures before it — same header / payload /
// notes / actions spine, same identifier scheme, same "it discloses, it does not
// decide" split — so a listener who saw either of those recognises this one.
//
// IT DISCLOSES; IT DOES NOT DECIDE. Accepting calls back into the section, which
// records consent and turns the switch on; ``MCPExternalAccessModel/apply(settings:)``
// re-checks the record for itself before it binds anything, so a second entry point
// added later inherits the gate instead of bypassing it.
//
// The two numbers on screen come from ``ToolProfile/external`` and the listener's own
// port setting, forwarded through ``ExternalAccessDisclosure``. Nothing is restated.
import DesignSystem
import SwiftUI

/// The external-access disclosure the loopback MCP server must clear before it binds.
struct IntelligenceExternalAccessConsentSheet: View {
    let disclosure: ExternalAccessDisclosure
    /// Runs on acceptance: records consent and switches external access on.
    let onAccept: @MainActor () -> Void
    /// Runs on refusal. Nothing is written and the switch stays off.
    let onDecline: @MainActor () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.large) {
            header
            payload
            controlGrant
            notes
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 480)
        .background(tokens.colors.canvas.resolve(scheme))
    }
}

// MARK: - Header

private extension IntelligenceExternalAccessConsentSheet {
    func identifier(_ element: String) -> String {
        "intelligence.externalAccess.consent.\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityHidden(true)
                Text(PreferencesStrings.externalAccessConsentTitle)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier(identifier("sheet"))
            }
            Text(PreferencesStrings.externalAccessConsentLead)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Payload

private extension IntelligenceExternalAccessConsentSheet {
    var payload: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(PreferencesStrings.externalAccessConsentPayloadHeading)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            payloadRow(PreferencesStrings.externalAccessConsentNamesItem)
            payloadRow(PreferencesStrings.externalAccessConsentFacetsItem)
            payloadRow(PreferencesStrings.externalAccessConsentStatsItem)
            payloadRow(PreferencesStrings.externalAccessConsentSizeItem(
                rows: disclosure.rowsPerLookup,
                characters: disclosure.charactersPerLookup
            ))
            payloadRow(PreferencesStrings.externalAccessConsentProposalsItem)
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

    /// The control grant gets its OWN block, not another payload bullet.
    ///
    /// Every line above it describes something a tool may READ. Taking the
    /// transport is a different kind of thing — audible, immediate, and attributable
    /// to nobody, since MacAMP cannot tell which program is connected — so folding it
    /// into the same list would let a listener accept it by reading past it. It is
    /// visually separated, warned rather than arrowed, and states that THIS sheet
    /// does not grant it.
    var controlGrant: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Image(systemName: "play.slash")
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityHidden(true)
                Text(PreferencesStrings.externalAccessConsentControlHeading)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            PreferenceCaption(text: PreferencesStrings.externalAccessConsentControlItem)
            PreferenceCaption(text: PreferencesStrings.externalAccessConsentControlOptIn)
        }
        .padding(tokens.spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                .fill(tokens.colors.surface.resolve(scheme))
        )
        .accessibilityIdentifier(identifier("control"))
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            PreferenceCaption(text: PreferencesStrings.externalAccessConsentExclusions)
            PreferenceCaption(text: PreferencesStrings.externalAccessConsentLoopback(port: disclosure.port))
            PreferenceCaption(text: PreferencesStrings.externalAccessConsentIdentity)
            PreferenceCaption(text: PreferencesStrings.externalAccessConsentReversible)
        }
    }
}

// MARK: - Actions

private extension IntelligenceExternalAccessConsentSheet {
    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            cancelButton
            acceptButton
        }
    }

    var cancelButton: some View {
        Button(role: .cancel) {
            onDecline()
            dismiss()
        } label: {
            Text(PreferencesStrings.externalAccessConsentCancel)
        }
        .keyboardShortcut(.cancelAction)
        .help(PreferencesStrings.externalAccessConsentCancelHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("cancelButton"))
    }

    var acceptButton: some View {
        Button {
            onAccept()
            dismiss()
        } label: {
            Text(PreferencesStrings.externalAccessConsentAccept)
        }
        .keyboardShortcut(.defaultAction)
        .help(PreferencesStrings.externalAccessConsentAcceptHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("acceptButton"))
    }
}
