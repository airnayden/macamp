// IntelligenceMCPServersSection — the list, the switches, and the two sheets.
//
// ── WHY IT SITS BELOW EXTERNAL ACCESS ────────────────────────────────────────
//
// The two sections are the same question from opposite ends. External access is
// "which programs may talk to MacAMP"; this is "which programs may MacAMP talk to".
// Reading them in that order means the listener has already met the vocabulary —
// a tool, a grant, a status row — by the time the riskier direction is on screen.
//
// Gated on the master switch for the same reason external access is: a tool the
// assistant may call is worth nothing while there is no assistant, and a live switch
// under a dead feature invites somebody to grant something that does nothing.
//
// ── THE VIEW HOLDS NO POLICY ─────────────────────────────────────────────────
//
// Every decision — may this be enabled, does the disclosure appear, what does the
// status say — is ``MCPServersSectionModel``'s. This file positions and paints. The
// switch's binding setter is one call into the model, so the consent gate cannot be
// bypassed by adding a second control here later.
import AIConnectorMCP
import DesignSystem
import SwiftUI

/// External MCP servers: the list, per-server switch, connection test, and the
/// trust disclosure the first enable must clear.
struct IntelligenceMCPServersSection: View {
    @Bindable var settings: AppSettings

    @State private var model: MCPServersSectionModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @MainActor
    init(settings: AppSettings) {
        self.settings = settings
        _model = State(initialValue: .live(settings: settings))
    }

    var body: some View {
        Section {
            Text(PreferencesStrings.mcpSection)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            PreferenceCaption(text: PreferencesStrings.mcpCaption)
            if !settings.intelligenceEnabled {
                PreferenceCaption(text: PreferencesStrings.mcpNeedsIntelligence)
            }
            if model.servers.isEmpty {
                PreferenceCaption(text: PreferencesStrings.mcpEmpty)
            }
            ForEach(model.servers) { server in
                IntelligenceMCPServerRow(model: model, server: server)
            }
            footer
        }
        .disabled(!settings.intelligenceEnabled)
        .sheet(item: $model.editing) { request in
            IntelligenceMCPServerEditSheet(request: request) { descriptor, secretValues in
                await model.save(descriptor, secretValues: secretValues)
            }
        }
        .sheet(item: $model.consenting) { disclosure in
            IntelligenceMCPConsentSheet(
                disclosure: disclosure,
                onAccept: { model.acceptConsent() },
                onDecline: { model.declineConsent() }
            )
        }
    }
}

// MARK: - Footer

private extension IntelligenceMCPServersSection {
    var footer: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(spacing: tokens.spacing.small) {
                Button { model.beginAdd() } label: {
                    Text(PreferencesStrings.mcpAdd)
                }
                .help(PreferencesStrings.mcpAddHelp)
                .pointingHandCursor()
                .accessibilityIdentifier("intelligence.mcp.addButton")
                Spacer(minLength: 0)
            }
            PreferenceCaption(text: PreferencesStrings.mcpTimeoutCaption(
                seconds: Int(model.probeTimeoutSeconds)
            ))
            if model.didFailToPersist {
                PreferenceCaption(text: PreferencesStrings.mcpPersistFailed)
            }
        }
    }
}

// MARK: - One server

/// One configured server: what it is, what it is doing, and the four things that
/// can be done to it.
private struct IntelligenceMCPServerRow: View {
    let model: MCPServersSectionModel
    let server: MCPServerDescriptor

    @State private var isTesting = false

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            identity
            statusRow
            actions
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }

    /// The NAME and the endpoint are things the listener typed — data, rendered
    /// verbatim. The transport kind is the app's own word for a category, so it is
    /// catalog copy.
    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: server.name)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                HStack(spacing: tokens.spacing.xxSmall) {
                    Text(transportLabel)
                    Text(verbatim: "·")
                    Text(verbatim: endpointDetail)
                }
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: tokens.spacing.xSmall)
            Toggle(isOn: enabledBinding) {
                Text(PreferencesStrings.mcpEnableHelp)
            }
            .labelsHidden()
            .help(PreferencesStrings.mcpEnableHelp)
            .accessibilityLabel(PreferencesStrings.mcpEnableHelp)
            .pointingHandCursor()
            .accessibilityIdentifier("intelligence.mcp.enableToggle.\(server.id.uuidString)")
        }
    }

    /// Switching ON is routed through the model so an unconsented server raises the
    /// disclosure and NOTHING is written. Switching OFF is immediate.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: { model.setEnabled($0, forServerID: server.id) }
        )
    }

    private var transportLabel: LocalizedStringResource {
        server.endpoint.command == nil
            ? PreferencesStrings.mcpTransportHTTP
            : PreferencesStrings.mcpTransportStdio
    }

    private var endpointDetail: String {
        server.endpoint.command ?? server.endpoint.address?.absoluteString ?? ""
    }
}

// MARK: - Status and actions

private extension IntelligenceMCPServerRow {
    var status: MCPServerConnectionStatus {
        model.status(for: server.id)
    }

    var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(statusMessage)
                .font(tokens.typography.caption.font)
                .foregroundStyle(statusTint)
                .fixedSize(horizontal: false, vertical: true)
            if case let .unreachable(diagnostic) = status {
                Text(verbatim: diagnostic)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .accessibilityIdentifier("intelligence.mcp.failureReason.\(server.id.uuidString)")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("intelligence.mcp.status.\(server.id.uuidString)")
    }

    var statusMessage: LocalizedStringResource {
        switch status {
        case .disabled: PreferencesStrings.mcpStatusDisabled
        case .untested: PreferencesStrings.mcpStatusUntested
        case .testing: PreferencesStrings.mcpStatusTesting
        case let .connected(toolCount): PreferencesStrings.mcpStatusConnected(tools: toolCount)
        case .unreachable: PreferencesStrings.mcpStatusUnreachable
        }
    }

    var statusTint: Color {
        switch status {
        case .connected: tokens.colors.success.resolve(scheme)
        case .unreachable: tokens.colors.warning.resolve(scheme)
        case .disabled, .untested, .testing: tokens.colors.textTertiary.resolve(scheme)
        }
    }

    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            testButton
            editButton
            removeButton
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    var testButton: some View {
        Button {
            isTesting = true
            Task {
                await model.test(serverID: server.id)
                isTesting = false
            }
        } label: {
            Text(PreferencesStrings.mcpTest)
        }
        .disabled(isTesting)
        .help(PreferencesStrings.mcpTestHelp)
        .pointingHandCursor()
        .accessibilityIdentifier("intelligence.mcp.testButton.\(server.id.uuidString)")
    }

    var editButton: some View {
        Button { model.beginEdit(server) } label: {
            Text(PreferencesStrings.mcpEdit)
        }
        .help(PreferencesStrings.mcpEditHelp)
        .pointingHandCursor()
        .accessibilityIdentifier("intelligence.mcp.editButton.\(server.id.uuidString)")
    }

    var removeButton: some View {
        Button(role: .destructive) {
            Task { await model.remove(serverID: server.id) }
        } label: {
            Text(PreferencesStrings.mcpRemove)
        }
        .help(PreferencesStrings.mcpRemoveHelp)
        .pointingHandCursor()
        .accessibilityIdentifier("intelligence.mcp.removeButton.\(server.id.uuidString)")
    }
}
