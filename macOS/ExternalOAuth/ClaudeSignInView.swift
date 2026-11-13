// ClaudeSignInView — the "Sign in with Claude" surface.
//
// Renders ``ClaudeSignInModel/Phase`` and nothing else, so every branch the flow
// can be in has exactly one appearance. Shaped as a plain `VStack` rather than a
// `Section` so it composes both inside a Preferences `Form` and as a sheet body —
// todo 15's per-connector configuration sheet is the intended host.
//
// This file lives in `macOS/ExternalOAuth/`, a buildable folder attached to
// `macampMac` — the one macOS app target — which defines MACAMP_EXTERNAL_OAUTH.
// See `ExternalOAuthComposition.swift` for the guard that keeps the folder and
// the flag together.
import AIConnectorKitOAuth
import DesignSystem
import SwiftUI

/// The Claude Pro/Max sign-in flow: approve in a browser, paste the code back.
struct ClaudeSignInView: View {
    @Bindable var model: ClaudeSignInModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            Text(ExternalOAuthStrings.claudeTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            PreferenceCaption(text: ExternalOAuthStrings.claudeCaption)
            ClaudeSignInStatusRow(phase: model.phase)
            if model.isUsingCLISession {
                PreferenceCaption(text: ExternalOAuthStrings.claudeCLICaption)
                    .accessibilityIdentifier("externalOAuth.claude.cliCaption")
            }
            if model.isAwaitingCode {
                codeEntry
            }
            actions
        }
        .task { await model.refreshStatus() }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            PreferenceCaption(text: ExternalOAuthStrings.claudeCodeInstructions)
            TextField(
                text: $model.pastedValue,
                prompt: Text(ExternalOAuthStrings.claudeCodePrompt),
                label: { Text(ExternalOAuthStrings.claudeCodeLabel) }
            )
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel(Text(ExternalOAuthStrings.claudeCodeLabel))
            .accessibilityIdentifier("externalOAuth.claude.codeField")
            .onSubmit { complete() }
        }
    }

    private var actions: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            if model.isAwaitingCode {
                Button(action: complete) { Text(ExternalOAuthStrings.claudeComplete) }
                    .disabled(!model.canComplete)
                    .help(ExternalOAuthStrings.claudeCompleteHelp)
                    .accessibilityIdentifier("externalOAuth.claude.completeButton")
                    .pointingHandCursor()
                Button(action: model.reopenApprovalPage) { Text(ExternalOAuthStrings.claudeReopen) }
                    .help(ExternalOAuthStrings.claudeReopenHelp)
                    .accessibilityIdentifier("externalOAuth.claude.reopenButton")
                    .pointingHandCursor()
                Button(action: model.cancel) { Text(ExternalOAuthStrings.claudeCancel) }
                    .help(ExternalOAuthStrings.claudeCancelHelp)
                    .accessibilityIdentifier("externalOAuth.claude.cancelButton")
                    .pointingHandCursor()
            } else if model.isSignedIn {
                // A borrowed session gets its own wording: "Sign Out" beside a
                // credential this app can never delete would promise a removal
                // that does not happen, and the listener would be right to file
                // the next launch's re-appearance as a bug.
                Button { Task { await model.signOut() } } label: {
                    Text(model.isUsingCLISession
                        ? ExternalOAuthStrings.claudeStopUsingCLI
                        : ExternalOAuthStrings.claudeSignOut)
                }
                .help(model.isUsingCLISession
                    ? ExternalOAuthStrings.claudeStopUsingCLIHelp
                    : ExternalOAuthStrings.claudeSignOutHelp)
                .accessibilityIdentifier("externalOAuth.claude.signOutButton")
                .pointingHandCursor()
            } else {
                Button(action: model.beginSignIn) { Text(ExternalOAuthStrings.claudeSignIn) }
                    .help(ExternalOAuthStrings.claudeSignInHelp)
                    .accessibilityIdentifier("externalOAuth.claude.signInButton")
                    .pointingHandCursor()
            }
        }
    }

    private func complete() {
        guard model.canComplete else { return }
        Task { await model.completeSignIn() }
    }
}

// MARK: - Status row

/// One line per ``ClaudeSignInModel/Phase``, tinted by whether it is good news.
///
/// `internal` rather than `private` so ``signedInMessage(tier:viaCLI:)`` — the
/// mapping that decides whether the listener is told their session came from the
/// CLI — is reachable from `macampMacTests`. A `private` type is invisible even
/// to `@testable`.
struct ClaudeSignInStatusRow: View {
    let phase: ClaudeSignInModel.Phase

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LabeledContent {
            Label {
                Text(message)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .accessibilityIdentifier("externalOAuth.claude.status")
        } label: {
            Text(ExternalOAuthStrings.claudeStatusLabel)
        }
    }

    private var message: LocalizedStringResource {
        switch phase {
        case .signedOut: ExternalOAuthStrings.claudeStatusSignedOut
        case .awaitingCode: ExternalOAuthStrings.claudeStatusAwaitingCode
        case .exchanging: ExternalOAuthStrings.claudeStatusExchanging
        case let .signedIn(tier, viaCLI): Self.signedInMessage(tier: tier, viaCLI: viaCLI)
        case let .failed(failure): failure.message
        }
    }

    static func signedInMessage(tier: String?, viaCLI: Bool) -> LocalizedStringResource {
        guard let tier, tier.isEmpty == false else {
            return viaCLI
                ? ExternalOAuthStrings.claudeStatusSignedInViaCLI
                : ExternalOAuthStrings.claudeStatusSignedIn
        }
        return viaCLI
            ? ExternalOAuthStrings.claudeStatusSignedInViaCLI(tier: tier)
            : ExternalOAuthStrings.claudeStatusSignedIn(tier: tier)
    }

    private var symbol: String {
        switch phase {
        case .signedIn: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .exchanging: "arrow.triangle.2.circlepath"
        case .signedOut, .awaitingCode: "person.crop.circle"
        }
    }

    private var tint: Color {
        switch phase {
        case .signedIn: tokens.colors.success.resolve(scheme)
        case .failed: tokens.colors.danger.resolve(scheme)
        case .signedOut, .awaitingCode, .exchanging: tokens.colors.textSecondary.resolve(scheme)
        }
    }
}

#Preview {
    ClaudeSignInView(model: ExternalOAuthComposition.previewSignInModel())
        .designTokens(.standard)
        .padding()
        .frame(width: 420)
}
