// IntelligenceMCPConsentSheet — the last screen before an outside server's tools
// reach the model.
//
// Shaped deliberately like ``IntelligenceLibraryBrowsingConsentSheet`` and
// ``IntelligenceExternalAccessConsentSheet``: same header/payload/notes/actions
// spine, same identifier scheme, same "it discloses, it does not decide" split. A
// listener who saw one of those recognises this one.
//
// IT DISCLOSES; IT DOES NOT DECIDE. Accepting calls back into
// ``MCPServersSectionModel/acceptConsent()``, which records consent through
// `MCPServerConfigStore` — the only writer of that record — and only then flips the
// switch. Declining writes nothing at all, which is the half a test can check and a
// screenshot cannot.
//
// The three risk items are ``IntelligenceMCPConsentStrings``' subject; the fourth,
// naming the actual command, appears only for a command server, because a category
// warning a listener cannot connect to the row they are looking at is a warning they
// will learn to click past.
import DesignSystem
import SwiftUI

/// The trust disclosure an external MCP server must clear before its first enable.
struct IntelligenceMCPConsentSheet: View {
    let disclosure: MCPServerConsentDisclosure
    /// Runs on acceptance. Records consent, then enables the server.
    let onAccept: @MainActor () -> Void
    /// Runs on refusal. Nothing is written; the switch stays off.
    let onDecline: @MainActor () -> Void

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
        .frame(width: 480)
        .background(tokens.colors.canvas.resolve(scheme))
    }
}

// MARK: - Header

private extension IntelligenceMCPConsentSheet {
    /// `intelligence.mcp.consent.<uuid>.<element>` — built from the server id, so
    /// two servers' sheets never collide in the accessibility hierarchy.
    func identifier(_ element: String) -> String {
        "intelligence.mcp.consent.\(disclosure.id.uuidString).\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityHidden(true)
                Text(PreferencesStrings.mcpConsentTitle)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier(identifier("sheet"))
            }
            Text(PreferencesStrings.mcpConsentLead(server: disclosure.serverName))
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Disclosure

private extension IntelligenceMCPConsentSheet {
    /// Three risks that are true of every external server, then — for a command
    /// server only — the program this particular one would start.
    var payload: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(PreferencesStrings.mcpConsentHeading)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            payloadRow(PreferencesStrings.mcpConsentInjectionItem, element: "injection")
            payloadRow(PreferencesStrings.mcpConsentPlaybackItem, element: "playback")
            payloadRow(PreferencesStrings.mcpConsentProcessItem, element: "process")
            if let command = disclosure.command {
                payloadRow(
                    PreferencesStrings.mcpConsentCommandItem(command: command),
                    element: "command"
                )
            }
        }
        .padding(tokens.spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                .fill(tokens.colors.surface.resolve(scheme))
        )
        .accessibilityIdentifier(identifier("payload"))
    }

    func payloadRow(_ text: LocalizedStringResource, element: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
                .accessibilityHidden(true)
            Text(text)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier(element))
            Spacer(minLength: 0)
        }
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            PreferenceCaption(text: PreferencesStrings.mcpConsentReviewNote)
            PreferenceCaption(text: PreferencesStrings.mcpConsentReversibleNote)
        }
    }
}

// MARK: - Actions

private extension IntelligenceMCPConsentSheet {
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
            Text(PreferencesStrings.mcpConsentCancel)
        }
        .keyboardShortcut(.cancelAction)
        .help(PreferencesStrings.mcpConsentCancelHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("cancelButton"))
    }

    var acceptButton: some View {
        Button {
            onAccept()
            dismiss()
        } label: {
            Text(PreferencesStrings.mcpConsentAccept)
        }
        .keyboardShortcut(.defaultAction)
        .help(PreferencesStrings.mcpConsentAcceptHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("acceptButton"))
    }
}

#Preview {
    IntelligenceMCPConsentSheet(
        disclosure: MCPServerConsentDisclosure(
            id: UUID(),
            serverName: "Example Tools",
            command: "npx"
        ),
        onAccept: {},
        onDecline: {}
    )
    .designTokens(.standard)
}
