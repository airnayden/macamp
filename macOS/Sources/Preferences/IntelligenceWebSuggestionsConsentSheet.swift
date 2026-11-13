// IntelligenceWebSuggestionsConsentSheet — the last screen before a song title
// leaves this Mac.
//
// Shaped deliberately like ``IntelligenceMCPConsentSheet`` and
// ``IntelligenceExternalAccessConsentSheet``: same header / payload / notes /
// actions spine, same identifier scheme, same "it discloses, it does not decide"
// split. A listener who saw either of those recognises this one.
//
// IT DISCLOSES; IT DOES NOT DECIDE. Accepting calls back into
// ``WebSuggestionsSectionModel/acceptConsent()``, which is the only writer of
// `AppSettings.webSuggestionsConsented`; declining writes nothing at all, which is
// the half a test can check and a screenshot cannot.
//
// The two provider names arrive as DATA on ``WebSuggestionsDisclosure`` and are
// interpolated into localized templates, never spelled into English copy — the same
// treatment an MCP server's own name gets.
import DesignSystem
import SwiftUI

/// The disclosure the web-suggestions feature must clear before its first enable.
struct IntelligenceWebSuggestionsConsentSheet: View {
    let disclosure: WebSuggestionsDisclosure
    /// Runs on acceptance. Records the disclosure, then enables the feature.
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

private extension IntelligenceWebSuggestionsConsentSheet {
    func identifier(_ element: String) -> String {
        "intelligence.webSuggestions.consent.\(element)"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
                Image(systemName: "globe.badge.chevron.backward")
                    .foregroundStyle(tokens.colors.warning.resolve(scheme))
                    .accessibilityHidden(true)
                Text(PreferencesStrings.webSuggestionsConsentTitle)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier(identifier("sheet"))
            }
            Text(PreferencesStrings.webSuggestionsConsentLead)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Disclosure

private extension IntelligenceWebSuggestionsConsentSheet {
    /// The four facts, in the order a listener needs them: what leaves and to whom
    /// (twice — two recipients), when it can leave at all, and what a key changes.
    var payload: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(PreferencesStrings.webSuggestionsConsentHeading)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            payloadRow(
                PreferencesStrings.webSuggestionsConsentSearchItem(provider: disclosure.searchProviderName),
                element: "search"
            )
            payloadRow(
                PreferencesStrings.webSuggestionsConsentVideoItem(provider: disclosure.videoProviderName),
                element: "video"
            )
            payloadRow(PreferencesStrings.webSuggestionsConsentCloudOnlyItem, element: "cloudOnly")
            payloadRow(PreferencesStrings.webSuggestionsConsentRateLimitItem, element: "rateLimit")
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
            Image(systemName: "arrow.up.right")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
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
            PreferenceCaption(text: PreferencesStrings.webSuggestionsConsentExclusions)
            PreferenceCaption(text: PreferencesStrings.webSuggestionsConsentReversible)
        }
    }
}

// MARK: - Actions

private extension IntelligenceWebSuggestionsConsentSheet {
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
            Text(PreferencesStrings.webSuggestionsConsentCancel)
        }
        .keyboardShortcut(.cancelAction)
        .help(PreferencesStrings.webSuggestionsConsentCancelHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("cancelButton"))
    }

    var acceptButton: some View {
        Button {
            onAccept()
            dismiss()
        } label: {
            Text(PreferencesStrings.webSuggestionsConsentAccept)
        }
        .keyboardShortcut(.defaultAction)
        .help(PreferencesStrings.webSuggestionsConsentAcceptHelp)
        .pointingHandCursor()
        .accessibilityIdentifier(identifier("acceptButton"))
    }
}

#Preview {
    IntelligenceWebSuggestionsConsentSheet(
        disclosure: .live,
        onAccept: {},
        onDecline: {}
    )
    .designTokens(.standard)
}
