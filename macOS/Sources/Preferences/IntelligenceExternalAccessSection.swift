// IntelligenceExternalAccessSection — the switch, the port, and the honest status.
//
// ── WHY IT LIVES IN THE INTELLIGENCE PANE, AFTER THE PROVIDER ────────────────
//
// Not its own tab: a twelfth tab pushes `PreferenceMetrics.windowMinWidth` past
// the eleven-tab floor for a control most listeners never touch, and — the real
// reason — external access is GATED ON the master Intelligence switch, because the
// only thing an external tool can write is a proposal, and a proposal is reviewed
// in a pane that does not exist when Intelligence is off. A separate tab would
// advertise an independence that is not there.
//
// It sits directly after the Provider section because the two answer the same
// question from opposite ends — "which vendor does MacAMP talk to" and "which
// programs may talk to MacAMP". Bundles and analysis are about what MacAMP does
// FOR the listener and belong after both.
//
// ── THE STATUS ROW IS THE FEATURE ────────────────────────────────────────────
//
// The port never silently moves, so the row has to be able to say "that port is
// taken". `MCPServerStatus` is that sentence as a value; every case is rendered,
// and `.failed` additionally shows the underlying reason verbatim rather than
// flattening four outcomes into "something went wrong".
import DesignSystem
import SwiftUI

/// External access: the disclosure-gated switch, the port, and what the server is
/// actually doing right now.
struct IntelligenceExternalAccessSection: View {
    @Bindable var settings: AppSettings
    let externalAccess: MCPExternalAccessModel

    @State private var disclosure: ExternalAccessDisclosure?
    @State private var portText = ""
    @FocusState private var isEditingPort: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            Text(PreferencesStrings.externalAccessSection)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Toggle(isOn: enabledBinding) {
                Text(PreferencesStrings.externalAccessToggle)
            }
            .accessibilityIdentifier("intelligence.externalAccess.toggle")
            PreferenceCaption(text: PreferencesStrings.externalAccessCaption)
            PreferenceCaption(text: PreferencesStrings.externalAccessReviewCaption)
            if !settings.intelligenceEnabled {
                PreferenceCaption(text: PreferencesStrings.externalAccessNeedsIntelligence)
            }
            controlToggle
            portField
            addressRow
            IntelligenceExternalAccessStatusRow(status: externalAccess.status)
        }
        .disabled(!settings.intelligenceEnabled)
        .onAppear { portText = String(settings.externalAccessPort) }
        .onChange(of: settings.externalAccessPort) { _, port in portText = String(port) }
        .onChange(of: isEditingPort) { _, editing in if !editing { commitPort() } }
        .sheet(item: $disclosure) { disclosure in
            IntelligenceExternalAccessConsentSheet(
                disclosure: disclosure,
                onAccept: {
                    settings.recordExternalAccessConsent()
                    settings.externalAccessEnabled = true
                },
                onDecline: {}
            )
        }
    }
}

// MARK: - Controls

private extension IntelligenceExternalAccessSection {
    /// Switching ON with no consent on file OFFERS the disclosure and writes
    /// nothing; the sheet's accept handler is the only thing that flips the stored
    /// switch. Switching OFF is unconditional and immediate.
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.externalAccessEnabled },
            set: { isOn in
                guard isOn else {
                    settings.externalAccessEnabled = false
                    return
                }
                guard settings.hasExternalAccessConsent else {
                    disclosure = ExternalAccessDisclosure(port: settings.externalAccessPort)
                    return
                }
                settings.externalAccessEnabled = true
            }
        )
    }

    /// The SECOND grant, nested under the first and independently off.
    ///
    /// Nested rather than a sibling section because it is meaningless on its own —
    /// there is nothing to control the player through until external access is
    /// serving — and `.disabled` beats hiding it: a switch that vanishes cannot be
    /// found again, and a listener deciding whether to allow external access at all
    /// deserves to see what the second half of the decision looks like.
    @ViewBuilder
    var controlToggle: some View {
        Toggle(isOn: $settings.externalAccessControlEnabled) {
            Text(PreferencesStrings.externalAccessControlToggle)
        }
        .disabled(!settings.externalAccessEnabled)
        .accessibilityIdentifier("intelligence.externalAccess.controlToggle")
        PreferenceCaption(text: PreferencesStrings.externalAccessControlCaption)
        if settings.intelligenceEnabled, !settings.externalAccessEnabled {
            PreferenceCaption(text: PreferencesStrings.externalAccessControlNeedsAccess)
        }
    }

    var portField: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                TextField(text: $portText) {
                    Text(PreferencesStrings.externalAccessPortLabel)
                }
                .labelsHidden()
                .frame(width: 110)
                .focused($isEditingPort)
                .onSubmit(commitPort)
                .accessibilityIdentifier("intelligence.externalAccess.port")
                PreferenceCaption(text: PreferencesStrings.externalAccessPortCaption)
            }
        } label: {
            Text(PreferencesStrings.externalAccessPortLabel)
        }
    }

    /// The one string a listener has to copy into a client. Rendered verbatim
    /// because it is an address, not copy — and selectable for the same reason.
    var addressRow: some View {
        LabeledContent {
            Text(verbatim: "http://127.0.0.1:\(settings.externalAccessPort)/mcp")
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .textSelection(.enabled)
                .accessibilityIdentifier("intelligence.externalAccess.address")
        } label: {
            Text(PreferencesStrings.externalAccessAddressLabel)
        }
    }

    /// An out-of-range or non-numeric entry REVERTS rather than being coerced: a
    /// port the listener did not type is a port no client will be told about.
    func commitPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1 ... 65535).contains(port) else {
            portText = String(settings.externalAccessPort)
            return
        }
        settings.externalAccessPort = port
    }
}

// MARK: - Status

/// Every case of ``MCPServerStatus``, rendered. Shaped like the pane's own
/// `IntelligenceStatusRow` so the two read as one family.
private struct IntelligenceExternalAccessStatusRow: View {
    let status: MCPServerStatus

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Label {
                    Text(message)
                        .font(tokens.typography.callout.font)
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .accessibilityIdentifier("intelligence.externalAccess.status")
                if case let .failed(reason) = status {
                    Text(verbatim: reason)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("intelligence.externalAccess.failureReason")
                }
            }
        } label: {
            Text(PreferencesStrings.externalAccessStatusLabel)
        }
    }

    private var message: LocalizedStringResource {
        switch status {
        case .stopped: PreferencesStrings.externalAccessStatusStopped
        case let .running(port): PreferencesStrings.externalAccessStatusRunning(port: port)
        case let .portUnavailable(port): PreferencesStrings.externalAccessStatusPortBusy(port: port)
        case .failed: PreferencesStrings.externalAccessStatusFailed
        }
    }

    private var symbol: String {
        switch status {
        case .running: "checkmark.circle.fill"
        case .stopped: "pause.circle"
        case .portUnavailable, .failed: "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .running: tokens.colors.success.resolve(scheme)
        case .stopped: tokens.colors.textSecondary.resolve(scheme)
        case .portUnavailable, .failed: tokens.colors.warning.resolve(scheme)
        }
    }
}
