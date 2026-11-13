// ChatGPTSignInView — the "Sign in with ChatGPT" surface.
//
// Renders ``ChatGPTSignInModel/Phase`` and nothing else, so every branch the flow
// can be in has exactly one appearance. Shaped as a plain `VStack` rather than a
// `Section`, mirroring ``ClaudeSignInView``, so it composes both inside a
// Preferences `Form` and as a sheet body.
//
// It has NO code field: this flow's redirect comes back to a loopback socket
// rather than to a page the listener copies from. That is the one structural
// difference from the Claude surface — see ``ChatGPTSignInModel``'s header.
//
// This file lives in `macOS/ExternalOAuth/`, a buildable folder attached to
// `macampMac` — the one macOS app target — which defines MACAMP_EXTERNAL_OAUTH.
import AIConnectorKitOAuth
import DesignSystem
import SwiftUI

/// The ChatGPT subscription sign-in flow: approve in a browser, come straight back.
struct ChatGPTSignInView: View {
    @Bindable var model: ChatGPTSignInModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            Text(ChatGPTOAuthStrings.title)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            PreferenceCaption(text: ChatGPTOAuthStrings.caption)
            ChatGPTSignInStatusRow(phase: model.phase)
            actions
        }
        .task { await model.refreshStatus() }
    }

    private var actions: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            if model.isAwaitingBrowser {
                Button(action: model.reopenApprovalPage) { Text(ChatGPTOAuthStrings.reopen) }
                    .help(ChatGPTOAuthStrings.reopenHelp)
                    .accessibilityIdentifier("externalOAuth.chatGPT.reopenButton")
                    .pointingHandCursor()
                Button(action: model.cancel) { Text(ChatGPTOAuthStrings.cancel) }
                    .help(ChatGPTOAuthStrings.cancelHelp)
                    .accessibilityIdentifier("externalOAuth.chatGPT.cancelButton")
                    .pointingHandCursor()
            } else if model.isSignedIn {
                Button { Task { await model.signOut() } } label: {
                    Text(ChatGPTOAuthStrings.signOut)
                }
                .help(ChatGPTOAuthStrings.signOutHelp)
                .accessibilityIdentifier("externalOAuth.chatGPT.signOutButton")
                .pointingHandCursor()
            } else {
                Button { Task { await model.beginSignIn() } } label: {
                    Text(ChatGPTOAuthStrings.signIn)
                }
                .help(ChatGPTOAuthStrings.signInHelp)
                .accessibilityIdentifier("externalOAuth.chatGPT.signInButton")
                .pointingHandCursor()
            }
        }
    }
}

// MARK: - Status row

/// One line per ``ChatGPTSignInModel/Phase``, tinted by whether it is good news.
///
/// `internal` rather than `private` so ``signedInMessage(tier:)`` is reachable from
/// `macampMacTests` — a `private` type is invisible even to `@testable`.
struct ChatGPTSignInStatusRow: View {
    let phase: ChatGPTSignInModel.Phase

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
            .accessibilityIdentifier("externalOAuth.chatGPT.status")
        } label: {
            Text(ChatGPTOAuthStrings.statusLabel)
        }
    }

    private var message: LocalizedStringResource {
        switch phase {
        case .signedOut: ChatGPTOAuthStrings.statusSignedOut
        case .awaitingBrowser: ChatGPTOAuthStrings.statusAwaitingBrowser
        case .exchanging: ChatGPTOAuthStrings.statusExchanging
        case let .signedIn(tier): Self.signedInMessage(tier: tier)
        case let .failed(failure): failure.message
        }
    }

    static func signedInMessage(tier: String?) -> LocalizedStringResource {
        guard let tier, tier.isEmpty == false else { return ChatGPTOAuthStrings.statusSignedIn }
        return ChatGPTOAuthStrings.statusSignedIn(tier: tier)
    }

    private var symbol: String {
        switch phase {
        case .signedIn: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .exchanging: "arrow.triangle.2.circlepath"
        case .signedOut, .awaitingBrowser: "person.crop.circle"
        }
    }

    private var tint: Color {
        switch phase {
        case .signedIn: tokens.colors.success.resolve(scheme)
        case .failed: tokens.colors.danger.resolve(scheme)
        case .signedOut, .awaitingBrowser, .exchanging: tokens.colors.textSecondary.resolve(scheme)
        }
    }
}

#Preview {
    ChatGPTSignInView(model: ExternalOAuthComposition.previewChatGPTSignInModel())
        .designTokens(.standard)
        .padding()
        .frame(width: 420)
}
